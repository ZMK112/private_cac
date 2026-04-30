# ── cac docker — runtime/build/env helpers ──────────────────────────

_dk_host_docker() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT docker "$@"
}

_dk_default_image_ref() {
  printf '%s\n' "${CAC_DOCKER_IMAGE_REPO}:${CAC_DOCKER_IMAGE_TAG}"
}

_dk_is_pinned_image_ref() {
  local image="$1" tail tag
  [[ -n "$image" ]] || return 1
  [[ "$image" == *@sha256:* ]] && return 0
  tail="${image##*/}"
  [[ "$tail" == *:* ]] || return 1
  tag="${tail##*:}"
  [[ -n "$tag" && "$tag" != "latest" ]]
}

_dk_resolve_image_ref() {
  local image
  image="${CAC_DOCKER_IMAGE:-$(_dk_read_env CAC_DOCKER_IMAGE)}"
  if [[ -n "$image" ]]; then
    printf '%s\n' "$image"
  else
    _dk_default_image_ref
  fi
}

_dk_refresh_image_ref() {
  _dk_image="$(_dk_resolve_image_ref)"
}

_dk_assert_pinned_image_ref() {
  local image="$1"
  if ! _dk_is_pinned_image_ref "$image"; then
    _err "Docker image reference must be pinned to an exact tag or digest"
    _err "Rejecting mutable image ref: $image"
    _err "Use ${CAC_DOCKER_IMAGE_REPO}:${CAC_DOCKER_IMAGE_TAG} or ${CAC_DOCKER_IMAGE_REPO}@sha256:<digest>"
    return 1
  fi
}

_dk_api_version_ge() {
  local left="$1" right="$2"
  python3 - "$left" "$right" <<'PY'
import sys

def norm(v: str):
    parts = [int(p or 0) for p in v.strip().split(".")]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])

print("1" if norm(sys.argv[1]) >= norm(sys.argv[2]) else "0")
PY
}

_dk_image_docker_client_api() {
  local api
  api="$(
    _dk_host_docker run --rm --entrypoint /usr/local/bin/docker-real "$_dk_image" version --format '{{.Client.APIVersion}}' 2>/dev/null |
      head -n1 | tr -d '\r\n'
  )"
  [[ -n "$api" ]] && printf '%s\n' "$api"
}

_dk_assert_docker_cli_compat() {
  local host_min_api client_api
  _dk_assert_pinned_image_ref "$_dk_image" || return 1
  host_min_api="$(_dk_host_docker version --format '{{.Server.MinAPIVersion}}' 2>/dev/null | tr -d '\r\n')"
  client_api="$(_dk_image_docker_client_api || true)"

  [[ -n "$host_min_api" ]] || return 0
  [[ -n "$client_api" ]] || {
    _warn "Could not determine the bundled Docker CLI API version for $_dk_image"
    return 0
  }

  if [[ "$(_dk_api_version_ge "$client_api" "$host_min_api")" != "1" ]]; then
    _err "Bundled Docker CLI API $client_api is older than host Docker's minimum API $host_min_api"
    _err "Update cac or rebuild the Docker image with a newer Docker CLI before starting Docker mode"
    return 1
  fi
}

_dk_host_docker_socket() {
  local socket
  socket="$(
    _dk_host_docker context inspect 2>/dev/null |
      awk -F'"' '/"Host": "unix:\/\//{print $4; exit}'
  )"
  socket="${socket#unix://}"
  if [[ -n "$socket" ]]; then
    printf '%s\n' "$socket"
  else
    printf '%s\n' "/var/run/docker.sock"
  fi
}

_dk_workspace_host_abs() {
  pwd -P
}

_dk_workspace_host_current() {
  local container_name source
  container_name=$(_dk_read_env CAC_CONTAINER_NAME)
container_name="${container_name:-boris-main}"
  source=$(_dk_host_docker inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$container_name" 2>/dev/null || true)
  if [[ -n "$source" ]]; then
    printf '%s\n' "$source"
  else
    _dk_workspace_host_abs
  fi
}

_dk_init() {
  local docker_dir
  docker_dir=$(_docker_dir)
  if [[ -z "$docker_dir" ]]; then
    _err "Cannot find docker/ directory. Run from the cac repo, or clone it first."
    _err "  git clone https://github.com/nmhjklnm/cac.git && cd cac"
    return 1
  fi
  _dk_env_file="${docker_dir}/.env"
  _dk_compose_base=(-f "${docker_dir}/docker-compose.yml")
  _dk_refresh_image_ref
}

_dk_can_build_local() {
  local docker_dir repo_root
  docker_dir=$(_docker_dir)
  repo_root="${docker_dir%/docker}"
  [[ -f "${docker_dir}/${_dk_build_file}" ]] &&
  [[ -f "${docker_dir}/Dockerfile" ]] &&
  [[ -d "${repo_root}/src" ]] &&
  [[ -f "${repo_root}/build.sh" ]]
}

_dk_force_local_rebuild() {
  [[ "${CAC_DOCKER_REBUILD:-0}" == "1" ]]
}

_dk_wants_local_build() {
  local flag
  flag="${CAC_DOCKER_BUILD_LOCAL:-$(_dk_read_env CAC_DOCKER_BUILD_LOCAL)}"
  [[ "$flag" == "1" || "$flag" == "true" ]] || _dk_force_local_rebuild
}

_dk_should_build_local() {
  _dk_can_build_local && _dk_wants_local_build
}

_dk_guess_build_proxy_url() {
  local mode="$1" raw="$2" scheme="" rest="" auth="" host="" port="" compact_user="" compact_pass=""
  [[ -n "$raw" ]] || return 0
  raw="$(_dk_canonicalize_proxy_uri "$raw" 2>/dev/null || printf '%s\n' "$raw")"

  case "$raw" in
    *://*)
      case "$raw" in
        socks5://*|socks5h://*|http://*|https://*)
          printf '%s\n' "$(_dk_normalize_proxy_uri "$mode" "$raw")"
          return 0
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    *)
      IFS=: read -r host port compact_user compact_pass <<<"$raw"
      [[ -n "$host" && -n "$port" ]] || return 0
      auth=""
      if [[ -n "$compact_user" ]]; then
        auth="${compact_user}:${compact_pass}@"
      fi
      if [[ "$mode" == "local" && ( "$host" == "127.0.0.1" || "$host" == "localhost" ) ]]; then
        host="host.docker.internal"
      fi
      printf 'socks5h://%s%s:%s\n' "$auth" "$host" "$port"
      return 0
      ;;
  esac
}

_dk_build_proxy_hint() {
  local mode="$1" proxy_uri="$2" suggestion=""
  suggestion="$(_dk_guess_build_proxy_url "$mode" "$proxy_uri")"

  _warn "Docker image builds use the host/build network by default."
  _warn "Runtime \033[1mPROXY_URI\033[0m only affects the protected container after it starts; it does not automatically proxy image-build downloads."
  _warn "If the build failed while downloading external assets such as \033[1mclaude.ai/install.sh\033[0m, set \033[1mBUILD_PROXY\033[0m in \033[1m$_dk_env_file\033[0m and retry."

  if [[ -n "$suggestion" ]]; then
    _info "Suggested setting:"
    printf '  BUILD_PROXY=%s\n' "$suggestion"
  else
    _info "Suggested setting:"
    printf '  BUILD_PROXY=socks5h://host.docker.internal:7890\n'
    _info "Use a standard HTTP/SOCKS proxy URL for BUILD_PROXY. Share links such as \033[1mss://\033[0m or \033[1mvmess://\033[0m cannot be passed to curl directly."
  fi

  _info "Then retry with: \033[1mcac docker create\033[0m"
}

_dk_build_runtime_image_locally() {
  local mode proxy_uri
  mode="$(_dk_get_mode)"
  proxy_uri="${PROXY_URI:-$(_dk_read_env PROXY_URI)}"
  if _dk_force_local_rebuild; then
    _info "Rebuilding local images..."
    if ! _dk_compose build; then
      _dk_build_proxy_hint "$mode" "$proxy_uri"
      return 1
    fi
  elif _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
    _info "Local image already present, refreshing docker-proxy..."
    if ! _dk_compose build docker-proxy; then
      _dk_build_proxy_hint "$mode" "$proxy_uri"
      return 1
    fi
  else
    _info "Building local images..."
    if ! _dk_compose build; then
      _dk_build_proxy_hint "$mode" "$proxy_uri"
      return 1
    fi
  fi
}

_dk_prepare_pinned_runtime_image() {
  _info "Building docker-proxy image..."
  _dk_compose build docker-proxy

  if _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
    _info "Pinned image already present: \033[1m$_dk_image\033[0m"
    return 0
  fi

  _info "Pulling pinned image: \033[1m$_dk_image\033[0m"
  if _dk_host_docker pull "$_dk_image"; then
    return 0
  fi

  if _dk_can_build_local; then
    _warn "Pinned image pull failed; falling back to an exact local source build for \033[1m$_dk_image\033[0m"
    CAC_DOCKER_BUILD_LOCAL=1 _dk_build_runtime_image_locally
    return $?
  fi

  _err "Pinned image pull failed and no local source build fallback is available"
  return 1
}

_dk_load_env() {
  # shellcheck disable=SC1090  # dynamic env file path
  [[ -f "$_dk_env_file" ]] && set -a && source "$_dk_env_file" && set +a
  unset DOCKER_HOST DOCKER_CONTEXT 2>/dev/null || true
}

_dk_read_env() {
  local key="$1"
  [[ -f "$_dk_env_file" ]] && grep -m1 "^${key}=" "$_dk_env_file" 2>/dev/null | cut -d= -f2- || echo ""
}

_dk_write_env() {
  local key="$1" value="$2"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$_dk_env_file" ]]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $0 ~ ("^" k "=") { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' "$_dk_env_file" > "$tmp" && mv "$tmp" "$_dk_env_file"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
    mv "$tmp" "$_dk_env_file"
  fi
}

_dk_delete_env_keys() {
  [[ -f "$_dk_env_file" ]] || return 0
  local tmp keys
  tmp=$(mktemp)
  keys="$*"
  awk -v keys="$keys" '
    BEGIN {
      n = split(keys, arr, " ")
      for (i = 1; i <= n; i++) drop[arr[i]] = 1
    }
    {
      key = $0
      sub(/=.*/, "", key)
      if (!(key in drop)) print
    }
  ' "$_dk_env_file" > "$tmp" && mv "$tmp" "$_dk_env_file"
}

_dk_prompt_value() {
  local label="$1" default="${2:-}" required="${3:-0}" input=""
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "  ${label} [${default}]: " input
    else
      read -r -p "  ${label}: " input
    fi
    input="${input:-$default}"
    if [[ "$required" == "1" && -z "$input" ]]; then
      _warn "${label} is required"
      continue
    fi
    printf '%s\n' "$input"
    return 0
  done
}

_dk_prompt_yes_no() {
  local label="$1" default="${2:-N}" input=""
  while true; do
    read -r -p "  ${label} [${default}]: " input
    input="${input:-$default}"
    case "$input" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *)
        _warn "Please answer y or n"
        ;;
    esac
  done
}

_dk_proxy_parse_tsv() {
  local uri="$1" docker_dir
  docker_dir="$(_docker_dir)"
  python3 - "$docker_dir" "$uri" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from lib.protocols import parse

proxy = parse(sys.argv[2])
print("\t".join([
    proxy.type,
    proxy.server,
    str(proxy.port),
    proxy.username,
    proxy.password,
]))
PY
}

_dk_canonicalize_proxy_uri() {
  local raw="$1" docker_dir
  case "$raw" in
    socks://*)
      docker_dir="$(_docker_dir)"
      python3 - "$docker_dir" "$raw" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from lib.protocols import parse

proxy = parse(sys.argv[2])
auth = ""
if proxy.username:
    auth = proxy.username
    if proxy.password:
        auth += f":{proxy.password}"
    auth += "@"
print(f"socks5://{auth}{proxy.server}:{proxy.port}")
PY
      return 0
      ;;
  esac

  printf '%s\n' "$raw"
}

_dk_proxy_uri_for_host_probe() {
  local mode="$1" raw="$2" probe_uri=""
  probe_uri="$(_dk_canonicalize_proxy_uri "$raw")" || return 1
  if [[ "$mode" == "local" ]]; then
    probe_uri="${probe_uri//host.docker.internal/127.0.0.1}"
  fi
  if [[ "$probe_uri" != *"://"* ]]; then
    probe_uri="socks5h://${probe_uri}"
  fi
  printf '%s\n' "$probe_uri"
}

_dk_tcp_probe() {
  local host="$1" port="$2"
  python3 - "$host" "$port" <<'PY'
import socket
import sys

try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5):
        pass
except OSError:
    raise SystemExit(1)
PY
}

_dk_proxy_http_probe() {
  local proxy_url="$1" url
  for url in \
    "https://api.ipify.org" \
    "https://www.google.com/generate_204"
  do
    if curl --proxy "$proxy_url" --connect-timeout 8 --max-time 15 -fsS -o /dev/null "$url" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

_dk_probe_proxy_uri() {
  local raw="$1" mode="$2" probe_uri="" info="" proxy_type="" server="" port="" _user="" _pass=""
  probe_uri="$(_dk_proxy_uri_for_host_probe "$mode" "$raw")" || {
    _warn "Proxy probe failed: could not normalize the proxy URI"
    return 1
  }

  info="$(_dk_proxy_parse_tsv "$probe_uri" 2>/dev/null)" || {
    _warn "Proxy probe failed: unsupported or invalid proxy format"
    return 1
  }
  IFS=$'\t' read -r proxy_type server port _user _pass <<<"$info"
  if [[ -z "$proxy_type" || -z "$server" || -z "$port" ]]; then
    _warn "Proxy probe failed: incomplete proxy endpoint information"
    return 1
  fi

  if ! _dk_tcp_probe "$server" "$port"; then
    _warn "Proxy probe failed: cannot reach \033[1m${server}:${port}\033[0m from the host"
    return 1
  fi

  case "$proxy_type" in
    http|socks5)
      if _dk_proxy_http_probe "$probe_uri"; then
        _ok "Proxy probe passed: outbound requests succeed through \033[1m${server}:${port}\033[0m"
      else
        _warn "Proxy endpoint \033[1m${server}:${port}\033[0m is reachable, but outbound verification through it failed"
        _info "Fix or verify the proxy first, then rerun \033[1mcac docker setup\033[0m or validate with \033[1mcac docker check\033[0m after a manual restart"
        return 1
      fi
      return 0
      ;;
    shadowsocks|vmess|vless|trojan)
      _ok "Proxy probe reached the upstream endpoint: \033[1m${server}:${port}\033[0m"
      _info "Share-link probe is basic reachability only; run \033[1mcac docker check\033[0m after restart for end-to-end validation"
      return 0
      ;;
    *)
      _warn "Proxy probe failed: unsupported parsed proxy type \033[1m${proxy_type}\033[0m"
      return 1
      ;;
  esac
}

_dk_guess_child_proxy_url() {
  local mode="$1" raw="$2" host="" port="" scheme="" rest="" tail="" auth="" compact_user="" compact_pass=""
  [[ -z "$raw" ]] && return 0

  case "$raw" in
    *://*)
      case "$raw" in
        socks5://*|socks5h://*|http://*|https://*)
          scheme="${raw%%://*}"
          rest="${raw#*://}"
          if [[ "$rest" == *"@"* ]]; then
            auth="${rest%%@*}@"
            rest="${rest#*@}"
          fi
          host="${rest%%:*}"
          tail="${rest#*:}"
          port="${tail%%/*}"
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    *)
      scheme="socks5h"
      IFS=: read -r host port compact_user compact_pass <<<"$raw"
      if [[ -n "$compact_user" ]]; then
        auth="${compact_user}:${compact_pass}@"
      fi
      ;;
  esac

  [[ -n "$host" && -n "$port" ]] || return 0
  if [[ "$mode" == "local" ]] && [[ "$host" == "127.0.0.1" || "$host" == "localhost" ]]; then
    host="host.docker.internal"
  fi
  printf '%s://%s%s:%s\n' "$scheme" "$auth" "$host" "$port"
}

_dk_normalize_proxy_uri() {
  local mode="$1" raw="$2" scheme="" rest="" auth="" target=""
  raw="$(_dk_canonicalize_proxy_uri "$raw" 2>/dev/null || printf '%s\n' "$raw")"
  [[ "$mode" == "local" ]] || { printf '%s\n' "$raw"; return 0; }
  [[ -n "$raw" ]] || return 0

  case "$raw" in
    127.0.0.1:*|localhost:*)
      printf 'host.docker.internal:%s\n' "${raw#*:}"
      return 0
      ;;
    *://*)
      scheme="${raw%%://*}"
      rest="${raw#*://}"
      if [[ "$rest" == *"@"* ]]; then
        auth="${rest%%@*}@"
        target="${rest#*@}"
      else
        target="$rest"
      fi
      case "$target" in
        127.0.0.1:*|localhost:*)
          printf '%s://%shost.docker.internal:%s\n' "$scheme" "$auth" "${target#*:}"
          return 0
          ;;
      esac
      ;;
  esac

  printf '%s\n' "$raw"
}

_dk_default_child_no_proxy() {
  printf '%s\n' "localhost,127.0.0.1,::1,host.docker.internal"
}

_dk_detect_mode() {
  if _dk_host_docker info 2>/dev/null | grep -qi "docker desktop\|operating system:.*docker desktop\|platform.*desktop"; then
    echo "local"
  elif [[ "$(uname -s)" == "Darwin" ]] || [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
    echo "local"
  else
    echo "remote"
  fi
}

_dk_get_mode() {
  local mode
  mode=$(_dk_read_env DEPLOY_MODE)
  echo "${mode:-$(_dk_detect_mode)}"
}

_dk_compose_files() {
  local docker_dir mode
  docker_dir=$(_docker_dir)
  mode=$(_dk_get_mode)
  printf '%s ' "${_dk_compose_base[@]}"
  if _dk_should_build_local; then
    printf '%s ' "-f" "${docker_dir}/${_dk_build_file}"
  fi
  if [[ "$mode" == "local" ]]; then
    printf '%s ' "-f" "${docker_dir}/docker-compose.local.yml"
  else
    printf '%s ' "-f" "${docker_dir}/docker-compose.macvlan.yml"
  fi
  echo ""
}

_dk_compose() {
  local files workspace_host docker_socket
  # shellcheck disable=SC2207  # intentional word splitting
  files=($(_dk_compose_files))
  workspace_host=$(_dk_workspace_host_abs) || return 1
  docker_socket="$(_dk_host_docker_socket)"
  env -u DOCKER_HOST -u DOCKER_CONTEXT \
    CAC_WORKSPACE_HOST="$workspace_host" \
    CAC_HOST_DOCKER_SOCKET="$docker_socket" \
    docker compose "${files[@]}" "$@"
}

_dk_wait_runtime_ready() {
  local state="" pid1_uid="" docker_api_rc="" tries phase="" detail="" last_detail=""
  for tries in $(seq 1 90); do
    state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "")
    if [[ "$state" != "running" ]]; then
      phase="state"
      detail="${state:-starting}"
    else
      docker_api_rc="$(
        _dk_compose exec -T "$_dk_service" sh -lc "timeout 3 docker-real version >/dev/null 2>&1; printf '%s' \$?" 2>/dev/null |
          tr -d '\r\n'
      )"
      if [[ "$docker_api_rc" != "0" ]]; then
        phase="docker-api"
        detail="waiting"
      else
        pid1_uid="$(
          _dk_compose exec -T "$_dk_service" sh -lc "awk '/^Uid:/{print \$2; exit}' /proc/1/status" 2>/dev/null |
            tr -d '\r\n'
        )"
        if [[ -n "$pid1_uid" && "$pid1_uid" != "0" ]]; then
          return 0
        fi
        phase="pid1"
        detail="${pid1_uid:-unknown}"
      fi
    fi

    if [[ "$detail" != "$last_detail" ]]; then
      case "$phase" in
        state)
          _info "Waiting for main container state: \033[1m${detail}\033[0m"
          ;;
        docker-api)
          _info "Container running; waiting for in-container Docker API..."
          ;;
        pid1)
          _info "Docker API ready; waiting for PID 1 to drop privileges..."
          ;;
      esac
      last_detail="$detail"
    fi
    sleep 1
  done
  return 1
}

_dk_abort_startup() {
  _warn "Startup readiness timed out; stopping the Docker stack to avoid a half-started state"
  _dk_compose down >/dev/null 2>&1 || true
  _dk_shim_down >/dev/null 2>&1 || true
}

_dk_detect_network() {
  local iface gw addr ip prefix a b c d bits net_addr subnet container_last container_ip

  iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')

  if [[ -z "$iface" || -z "$gw" ]]; then
    _err "Cannot detect default network interface"
    return 1
  fi

  addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2; exit}') || addr=""
  [[ -z "$addr" ]] && { echo "error: cannot get address for $iface" >&2; return 1; }
  ip="${addr%/*}"
  prefix="${addr#*/}"

  IFS=. read -r a b c d <<< "$ip"
  bits=$((0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF))
  net_addr="$(( a & (bits >> 24 & 0xFF) )).$(( b & (bits >> 16 & 0xFF) )).$(( c & (bits >> 8 & 0xFF) )).$(( d & (bits & 0xFF) ))"
  subnet="${net_addr}/${prefix}"

  container_last=$(( (d + 100) % 254 + 1 ))
  container_ip="${a}.${b}.${c}.${container_last}"
  local shim_last=$(( container_last % 254 + 1 ))
  local shim_ip="${a}.${b}.${c}.${shim_last}"

  _dk_write_env HOST_INTERFACE "$iface"
  _dk_write_env MACVLAN_SUBNET "$subnet"
  _dk_write_env MACVLAN_GATEWAY "$gw"
  _dk_write_env MACVLAN_IP "$container_ip"
  _dk_write_env SHIM_IP "$shim_ip"

  printf "  Interface:  \033[1m%s\033[0m\n" "$iface"
  printf "  Host IP:    %s\n" "$ip"
  printf "  Gateway:    %s\n" "$gw"
  printf "  Container:  \033[1m%s\033[0m\n" "$container_ip"
}

_dk_shim_up() {
  [[ "$(_dk_get_mode)" != "remote" ]] && return 0
  _dk_load_env
  local parent="${HOST_INTERFACE:-}" cip="${MACVLAN_IP:-}" sip="${SHIM_IP:-}"
  [[ -z "$parent" || -z "$cip" || -z "$sip" ]] && return 0
  ip link show "$_dk_shim_if" &>/dev/null && return 0

  ip link add "$_dk_shim_if" link "$parent" type macvlan mode bridge
  ip addr add "${sip}/32" dev "$_dk_shim_if"
  ip link set "$_dk_shim_if" up
  ip route add "${cip}/32" dev "$_dk_shim_if" 2>/dev/null || true
}

_dk_shim_down() {
  ip link show "$_dk_shim_if" &>/dev/null && ip link del "$_dk_shim_if" 2>/dev/null || true
}
