#!/usr/bin/env bash
set -euo pipefail

SINGBOX_ENABLE="${SINGBOX_ENABLE:-1}"
DISABLE_IPV6="${DISABLE_IPV6:-1}"
HEALTHCHECK="${HEALTHCHECK:-1}"
CAC_PROFILE="${CAC_PROFILE:-default}"
CHERNY_TEMPLATE_DIR="${CHERNY_TEMPLATE_DIR:-/usr/local/share/cherny}"
CHERNY_IDENTITY_JSON="${CHERNY_TEMPLATE_DIR}/cherny.identity.json"
CHERNY_ENV_JSON="${CHERNY_TEMPLATE_DIR}/cherny.env.json"
CHERNY_PROMPT_JSON="${CHERNY_TEMPLATE_DIR}/cherny.prompt.json"
CHERNY_TELEMETRY_JSON="${CHERNY_TEMPLATE_DIR}/cherny.telemetry.json"

unset ALL_PROXY HTTP_PROXY HTTPS_PROXY all_proxy http_proxy https_proxy \
      NO_PROXY no_proxy 2>/dev/null || true

mkdir -p /workspace

if [[ "$DISABLE_IPV6" == "1" ]]; then
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
fi

_SINGBOX_PID=""
_DOCKER_ROUTE_SPEC=""
_PROXY_ROUTE_SPEC=""

docker_host_target() {
  local docker_host="${DOCKER_HOST:-}" target=""
  [[ -z "$docker_host" ]] && return 1

  case "$docker_host" in
    tcp://*)
      target="${docker_host#tcp://}"
      target="${target%%/*}"
      if [[ "$target" == \[*\]*:* ]]; then
        target="${target#\[}"
        target="${target%%]*}"
      else
        target="${target%%:*}"
      fi
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s\n' "$target"
}

proxy_host_target() {
  local proxy="${PROXY_URI:-}" target=""
  [[ -z "$proxy" ]] && return 1

  if [[ "$proxy" != *"://"* ]]; then
    printf '%s\n' "${proxy%%:*}"
    return 0
  fi

  python3 - "$proxy" <<'PY'
from urllib.parse import urlparse
import sys

raw = sys.argv[1]
scheme = raw.split("://", 1)[0].lower()
if scheme in {"http", "https", "socks5", "vless", "trojan"}:
    parsed = urlparse(raw)
    print(parsed.hostname or "")
PY
}

capture_named_route() {
  local target="$1" resolved="" route_line="" host_alias=""
  [[ -z "$target" ]] && return 0

  if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    resolved="$target"
  else
    resolved="$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    host_alias="$target"
  fi
  [[ -z "$resolved" ]] && return 0

  route_line="$(ip -4 route get "$resolved" 2>/dev/null | head -n1 || true)"
  [[ -z "$route_line" ]] && return 0

  local dev via src
  dev="$(awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<<"$route_line")"
  via="$(awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}' <<<"$route_line")"
  src="$(awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' <<<"$route_line")"
  [[ -z "$dev" ]] && return 0

  printf '%s|%s|%s|%s|%s\n' "${resolved}/32" "$dev" "$via" "$src" "$host_alias"
}

pin_named_route() {
  local spec="$1"
  [[ -z "$spec" ]] && return 0

  local dst dev via src host
  IFS='|' read -r dst dev via src host <<<"$spec"
  [[ -z "$dst" || -z "$dev" ]] && return 0

  local cmd=(ip route replace "$dst" dev "$dev")
  [[ -n "$via" ]] && cmd+=(via "$via")
  [[ -n "$src" ]] && cmd+=(src "$src")
  "${cmd[@]}" 2>/dev/null || true
  if [[ -n "$host" ]]; then
    grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" /etc/hosts 2>/dev/null || \
      printf '%s %s\n' "${dst%/32}" "$host" >> /etc/hosts
  fi
}

cherny_flatten_json() {
  local template="$1"
  python3 - "$template" <<'PY'
import json, sys

path = sys.argv[1]
data = json.load(open(path))
for key, value in data.items():
    if isinstance(value, list):
        value = ",".join(str(item) for item in value)
    print(f"{key}={value}")
PY
}

cherify_layer() {
  local template="$1" prefix="$2" dir="$3"
  [[ ! -f "$template" ]] && return
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    printf '%s\n' "$value" > "$dir/cherny.${prefix}.${key}"
    printf 'export CHERNY_%s_%s="%s"\n' "${prefix^^}" "${key^^}" "${value//\"/\\\"}" >> /root/.cac-env
  done < <(cherny_flatten_json "$template")
}

apply_cherny_identity() {
  local template="$CHERNY_IDENTITY_JSON" dir="$1"
  [[ ! -f "$template" ]] && return
  local device_id email user_id session_alias
  read -r device_id email user_id session_alias < <(
    python3 - "$template" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get('device_id',''))
print(data.get('email',''))
print(data.get('user_id',''))
print(data.get('session_alias',''))
PY
  )
  [[ -n "$device_id" ]] && {
    printf '%s\n' "$device_id" > "$dir/cherny.identity.device_id"
    printf 'export CAC_DEVICE_ID="%s"\n' "$device_id" >> /root/.cac-env
    printf 'export CHERNY_ID_DEVICE_ID="%s"\n' "$device_id" >> /root/.cac-env
  }
  [[ -n "$email" ]] && {
    printf '%s\n' "$email" > "$dir/cherny.identity.email"
    printf 'export CAC_EMAIL="%s"\n' "$email" >> /root/.cac-env
    printf 'export CHERNY_ID_EMAIL="%s"\n' "$email" >> /root/.cac-env
  }
  [[ -n "$user_id" ]] && {
    printf '%s\n' "$user_id" > "$dir/cherny.identity.user_id"
    printf 'export CAC_USER_ID="%s"\n' "$user_id" >> /root/.cac-env
    printf 'export CHERNY_ID_USER_ID="%s"\n' "$user_id" >> /root/.cac-env
  }
  [[ -n "$session_alias" ]] && {
    printf '%s\n' "$session_alias" > "$dir/cherny.identity.session_alias"
    printf 'export CHERNY_ID_SESSION_ALIAS="%s"\n' "$session_alias" >> /root/.cac-env
  }
}

apply_cherny_profile() {
  local dir="$1"
  apply_cherny_identity "$dir"
  cherify_layer "$CHERNY_ENV_JSON" "env" "$dir"
  cherify_layer "$CHERNY_PROMPT_JSON" "prompt" "$dir"
  cherify_layer "$CHERNY_TELEMETRY_JSON" "telemetry" "$dir"
}

wait_for_docker_host() {
  local docker_host="${DOCKER_HOST:-}"
  [[ -z "$docker_host" ]] && return 0

  for _ in $(seq 1 120); do
    DOCKER_HOST="$docker_host" /usr/local/bin/docker-real version >/dev/null 2>&1 && return 0
    sleep 0.25
  done

  echo "Docker API unavailable at ${docker_host}" >&2
  exit 1
}

_DOCKER_ROUTE_SPEC="$(capture_named_route "$(docker_host_target || true)")"
_PROXY_ROUTE_SPEC="$(capture_named_route "$(proxy_host_target || true)")"

if [[ "$SINGBOX_ENABLE" == "1" ]]; then
  mkdir -p /etc/sing-box
  python3 -m ccimage > /etc/sing-box/config.json \
    || { echo "Failed to generate sing-box config" >&2; exit 1; }

  sing-box run -c /etc/sing-box/config.json &
  _SINGBOX_PID=$!

  for _ in $(seq 1 150); do
    ip -o link show tun0 2>/dev/null && break
    kill -0 "$_SINGBOX_PID" 2>/dev/null || { echo "sing-box exited before TUN came up" >&2; exit 1; }
    sleep 0.05
  done

  _net="${TUN_ADDRESS:-172.19.0.1/30}"
  _base="${_net%/*}"
  _prefix="${_base%.*}"
  _last="${_base##*.}"
  TUN_DNS="${_prefix}.$(( _last + 1 ))"
  printf 'nameserver %s\noptions ndots:0\n' "$TUN_DNS" > /etc/resolv.conf
  pin_named_route "$_DOCKER_ROUTE_SPEC"
  pin_named_route "$_PROXY_ROUTE_SPEC"

  # ── Auto-detect timezone and locale from exit IP ──────────────
  _GEO_TZ="" _GEO_LANG=""
  _GEO_TZ="" _GEO_LANG=""
  if python3 -m ccimage.geo 2>/dev/null > /root/.cac-env; then
    source /root/.cac-env
    _GEO_TZ="${TZ:-}"
    _GEO_LANG="${LANG:-}"
    echo "Geo: ${TZ} / ${LANG}"
  fi

  # ── Auto-setup cac: install + create profile + activate ───────
  export HOME=/root
  export CAC_DIR="$HOME/.cac"
  export ENVS_DIR="$CAC_DIR/envs"

  if [[ ! -d "$CAC_DIR" ]]; then
    echo "Setting up cac..."
    cac setup 2>/dev/null || true
  fi

  # Create and activate profile if not complete
  _env_dir="$ENVS_DIR/$CAC_PROFILE"
  if [[ ! -f "$_env_dir/uuid" ]]; then
    echo "Creating cac profile: $CAC_PROFILE"
    mkdir -p "$_env_dir"

    _proxy_for_cac=""
    if [[ -n "${PROXY_URI:-}" ]] && [[ "$PROXY_URI" != *"://"* ]]; then
      IFS=: read -r _h _p _u _pw <<< "$PROXY_URI"
      _proxy_for_cac="socks5://${_u:+$_u:$_pw@}$_h:$_p"
    elif [[ -n "${PROXY_URI:-}" ]]; then
      _proxy_for_cac="$PROXY_URI"
    fi
    echo "${_proxy_for_cac:-none}" > "$_env_dir/proxy"

    # Generate identity
    uuidgen | tr '[:lower:]' '[:upper:]'           > "$_env_dir/uuid"
    uuidgen | tr '[:upper:]' '[:lower:]'           > "$_env_dir/stable_id"
    python3 -c "import os; print(os.urandom(32).hex())" > "$_env_dir/user_id"
    uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'    > "$_env_dir/machine_id"
    echo "boris-$(uuidgen | cut -d- -f1 | tr '[:upper:]' '[:lower:]')" > "$_env_dir/hostname"
    printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) > "$_env_dir/mac_address"

    # Timezone and language from geo detection
    echo "${_GEO_TZ:-Asia/Tokyo}"           > "$_env_dir/tz"
    echo "${_GEO_LANG:-ja_JP.UTF-8}"        > "$_env_dir/lang"

    # Generate mTLS client certificate
    if [[ -f "$CAC_DIR/ca/ca_key.pem" ]]; then
      openssl genrsa -out "$_env_dir/client_key.pem" 2048 2>/dev/null
      openssl req -new -key "$_env_dir/client_key.pem" \
        -subj "/CN=cac-client-${CAC_PROFILE}" \
        -out /tmp/cac-csr.pem 2>/dev/null
      openssl x509 -req -in /tmp/cac-csr.pem \
        -CA "$CAC_DIR/ca/ca_cert.pem" -CAkey "$CAC_DIR/ca/ca_key.pem" \
        -CAcreateserial -days 365 \
        -out "$_env_dir/client_cert.pem" 2>/dev/null
      rm -f /tmp/cac-csr.pem
    fi

    echo "  Profile: $CAC_PROFILE"
    echo "  Hostname: $(cat "$_env_dir/hostname")"
    echo "  UUID: $(cat "$_env_dir/uuid")"
  fi

  # Activate profile
  echo "$CAC_PROFILE" > "$CAC_DIR/current"
  rm -f "$CAC_DIR/stopped"

  # Export identity env vars for current session (so cac-check sees them)
  export CAC_HOSTNAME="$(cat "$_env_dir/hostname" 2>/dev/null)"
  export CAC_MAC="$(cat "$_env_dir/mac_address" 2>/dev/null)"
  export CAC_MACHINE_ID="$(cat "$_env_dir/machine_id" 2>/dev/null)"
  export CAC_USERNAME="devuser"
  export TZ="$(cat "$_env_dir/tz" 2>/dev/null || echo Asia/Tokyo)"
  export LANG="$(cat "$_env_dir/lang" 2>/dev/null || echo ja_JP.UTF-8)"
  export LC_ALL="$LANG"
  case "$LANG" in
    ja_JP.UTF-8) export LANGUAGE="ja_JP:ja" ;;
    *) export LANGUAGE="${LANG%%.*}" ;;
  esac
  hostname "$CAC_HOSTNAME" 2>/dev/null || true
  printf '%s\n' "$CAC_HOSTNAME" > /etc/hostname 2>/dev/null || true

  # Write all env vars to a single file, sourced by .bashrc
  {
    echo "export CAC_HOSTNAME=\"$CAC_HOSTNAME\""
    echo "export CAC_MAC=\"$CAC_MAC\""
    echo "export CAC_MACHINE_ID=\"$CAC_MACHINE_ID\""
    echo "export CAC_USERNAME=\"$CAC_USERNAME\""
    echo "export TZ=\"$TZ\""
    echo "export LANG=\"$LANG\""
    echo "export LC_ALL=\"$LC_ALL\""
    echo "export LANGUAGE=\"$LANGUAGE\""
    echo "export DOCKER_HOST=\"${DOCKER_HOST:-}\""
  } >> /root/.cac-env
  grep -q 'cac-env' /root/.bashrc 2>/dev/null || \
    echo '[ -f ~/.cac-env ] && source ~/.cac-env' >> /root/.bashrc
  grep -q 'docker-real' /root/.bashrc 2>/dev/null || \
    echo 'alias docker-real=/usr/local/bin/docker-real' >> /root/.bashrc

  apply_cherny_profile "$_env_dir"

  if [[ "$HEALTHCHECK" == "1" ]]; then
    echo "Running startup checks..."
    cac-check || echo "Warning: some checks failed (container will start anyway)" >&2
  fi

elif [[ "$SINGBOX_ENABLE" == "0" ]]; then
  if [[ -z "${PROXY_URI:-}" ]]; then
    echo "SINGBOX_ENABLE=0 but PROXY_URI not set" >&2
    exit 1
  fi
  if [[ "$PROXY_URI" == *"://"* ]]; then
    echo "SINGBOX_ENABLE=0 does not support share links. Use SINGBOX_ENABLE=1 or compact format." >&2
    exit 1
  fi
  IFS=: read -r h p u pw <<< "$PROXY_URI"
  PROXY_URL="socks5h://${u:+$u:$pw@}$h:$p"
  export ALL_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
  export all_proxy="$PROXY_URL" http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
  export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
  echo "SINGBOX_ENABLE=0: using env SOCKS only (not leak-safe)." >&2
else
  echo "SINGBOX_ENABLE must be 0 or 1" >&2
  exit 1
fi

wait_for_docker_host

_cleanup() {
  [[ -n "$_SINGBOX_PID" ]] && kill -TERM "$_SINGBOX_PID" 2>/dev/null && wait "$_SINGBOX_PID" 2>/dev/null || true
}
trap _cleanup EXIT INT TERM

exec "$@"
