# ── cac docker — 容器化部署管理 ─────────────────────────────────────

_info()  { printf '\033[36m▸\033[0m %b\n' "$*"; }
_ok()    { printf '\033[32m✓\033[0m %b\n' "$*"; }
_warn()  { printf '\033[33m!\033[0m %b\n' "$*"; }
_err()   { printf '\033[31m✗\033[0m %b\n' "$*" >&2; }

_dk_script_dir() {
  local ref target
  ref="${BASH_SOURCE[0]:-$0}"
  [[ "$ref" == /* ]] || ref="$(pwd)/$ref"
  while [[ -L "$ref" ]]; do
    target="$(readlink "$ref")" || break
    [[ "$target" == /* ]] || target="$(cd "$(dirname "$ref")" && pwd -P)/$target"
    ref="$target"
  done
  (cd "$(dirname "$ref")" && pwd -P)
}

_docker_dir() {
  local script_dir
  script_dir="$(_dk_script_dir)"

  for d in \
    "$script_dir/docker" \
    "$script_dir/../docker" \
    "$HOME/.cac/docker"
  do
    if [[ -d "$d" && -f "$d/docker-compose.yml" ]]; then
      (cd "$d" && pwd -P)
      return 0
    fi
  done

  echo ""
}

_dk_env_file=""
_dk_compose_base=()
_dk_service="cac"
_dk_shim_if="cac-docker-shim"
_dk_port_dir="/tmp/cac-docker-ports"
_dk_image="${CAC_DOCKER_IMAGE_REPO}:${CAC_DOCKER_IMAGE_TAG}"
_dk_build_file="docker-compose.build.yml"

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

_dk_build_runtime_image_locally() {
  if _dk_force_local_rebuild; then
    _info "Rebuilding local images..."
    _dk_compose build
  elif _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
    _info "Local image already present, refreshing docker-proxy..."
    _dk_compose build docker-proxy
  else
    _info "Building local images..."
    _dk_compose build
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

_dk_guess_child_proxy_url() {
  local mode="$1" raw="$2" host="" port="" scheme="" rest="" tail=""
  [[ -z "$raw" ]] && return 0

  case "$raw" in
    *://*)
      case "$raw" in
        socks5://*|socks5h://*|http://*|https://*)
          scheme="${raw%%://*}"
          rest="${raw#*://}"
          [[ "$rest" == *"@"* ]] && rest="${rest#*@}"
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
      IFS=: read -r host port _ <<<"$raw"
      ;;
  esac

  [[ -n "$host" && -n "$port" ]] || return 0
  if [[ "$mode" == "local" ]] && [[ "$host" == "127.0.0.1" || "$host" == "localhost" ]]; then
    host="host.docker.internal"
  fi
  printf '%s://%s:%s\n' "$scheme" "$host" "$port"
}

_dk_normalize_proxy_uri() {
  local mode="$1" raw="$2" scheme="" rest="" auth="" target=""
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
  local mode="$1"
  if [[ "$mode" == "local" ]]; then
    printf '%s\n' "localhost,127.0.0.1,::1,host.docker.internal"
  else
    printf '%s\n' "localhost,127.0.0.1,::1"
  fi
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

# ── Port forwarding ──────────────────────────────────────────────────

_dk_port_forward() {
  local port="$1" mode
  mode=$(_dk_get_mode)

  mkdir -p "$_dk_port_dir"
  local pidfile="${_dk_port_dir}/${port}.pid"
  if [[ -f "$pidfile" ]]; then
    local existing
    existing=$(cat "$pidfile" 2>/dev/null || true)
    case "$existing" in
      pid:*)
        if kill -0 "${existing#pid:}" 2>/dev/null; then
          _warn "Port $port already forwarded (pid ${existing#pid:})"
          return 0
        fi
        rm -f "$pidfile"
        ;;
      container:*)
        if [[ "$(_dk_host_docker inspect -f '{{.State.Running}}' "${existing#container:}" 2>/dev/null || echo false)" == "true" ]]; then
          _warn "Port $port already forwarded (container ${existing#container:})"
          return 0
        fi
        rm -f "$pidfile"
        ;;
      *)
        rm -f "$pidfile"
        ;;
    esac
  fi

  local cip
  if [[ "$mode" == "remote" ]]; then
    _dk_load_env
    cip="${MACVLAN_IP:-}"
    [[ -z "$cip" ]] && { _err "MACVLAN_IP not set. Run: cac docker setup"; return 1; }
    _dk_shim_up
  else
    cip=$(_dk_compose exec -T "$_dk_service" hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$cip" ]] && { _err "Cannot determine container IP"; return 1; }
  fi

  if [[ "$mode" == "local" ]]; then
    local target_name helper_name network_name helper_image gateway_name
    target_name=$(_dk_read_env CAC_CONTAINER_NAME)
    target_name="${target_name:-boris-main}"
    gateway_name=$(_dk_read_env CAC_DOCKER_PROXY_NAME)
    gateway_name="${gateway_name:-boris-gateway}"
    helper_name="${target_name}-port-${port}"
    network_name=$(_dk_host_docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$target_name" 2>/dev/null | head -n1)
    [[ -n "$network_name" ]] || { _err "Cannot determine container network"; return 1; }
    helper_image=$(_dk_host_docker inspect -f '{{.Config.Image}}' "$gateway_name" 2>/dev/null || echo "docker-docker-proxy:latest")

    _dk_host_docker rm -f "$helper_name" >/dev/null 2>&1 || true
    if ! _dk_host_docker run -d --rm \
      --name "$helper_name" \
      --network "$network_name" \
      -p "127.0.0.1:${port}:${port}" \
      --entrypoint socat \
      "$helper_image" \
      "TCP-LISTEN:${port},fork,reuseaddr,bind=0.0.0.0" \
      "TCP:${target_name}:${port}" >/dev/null; then
      _err "Failed to create local helper container for port $port"
      return 1
    fi
    echo "container:$helper_name" > "$pidfile"
    sleep 0.5
    if (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
      _ok "localhost:${port} → ${target_name}:${port} (container $helper_name)"
      return 0
    fi
    _dk_host_docker rm -f "$helper_name" >/dev/null 2>&1 || true
    rm -f "$pidfile"
    _err "Failed to forward port $port"
    return 1
  fi

  if command -v socat &>/dev/null; then
    socat TCP-LISTEN:"$port",fork,reuseaddr,bind=127.0.0.1 TCP:"${cip}":"$port" &
  elif command -v python3 &>/dev/null; then
    python3 -c "
import socket, threading
def fwd(src, dst):
    try:
        while d := src.recv(4096):
            dst.sendall(d)
    except: pass
    finally: src.close(); dst.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port)); s.listen(8)
while True:
    c, _ = s.accept()
    r = socket.create_connection(('$cip', $port))
    threading.Thread(target=fwd, args=(c,r), daemon=True).start()
    threading.Thread(target=fwd, args=(r,c), daemon=True).start()
" &
  else
    _err "Need socat or python3 for port forwarding"
    return 1
  fi
  local pid=$!
  echo "pid:$pid" > "$pidfile"
  sleep 0.3
  if kill -0 "$pid" 2>/dev/null; then
    _ok "localhost:${port} → ${cip}:${port} (pid $pid)"
  else
    _err "Failed to forward port $port"
    rm -f "$pidfile"
    return 1
  fi
}

_dk_port_stop() {
  local port="$1"
  local pidfile="${_dk_port_dir}/${port}.pid"
  if [[ -f "$pidfile" ]]; then
    local target
    target=$(cat "$pidfile" 2>/dev/null || true)
    case "$target" in
      pid:*)
        kill "${target#pid:}" 2>/dev/null || true
        ;;
      container:*)
        _dk_host_docker rm -f "${target#container:}" >/dev/null 2>&1 || true
        ;;
    esac
    rm -f "$pidfile"
    _ok "Stopped forwarding port $port"
  else
    _warn "Port $port is not being forwarded"
  fi
}

_dk_port_list() {
  mkdir -p "$_dk_port_dir"
  local found=0
  for pidfile in "$_dk_port_dir"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local port target
    port=$(basename "$pidfile" .pid)
    target=$(cat "$pidfile" 2>/dev/null || true)
    case "$target" in
      pid:*)
        if kill -0 "${target#pid:}" 2>/dev/null; then
          printf "  \033[32m●\033[0m localhost:%-6s (pid %s)\n" "$port" "${target#pid:}"
          found=1
        else
          rm -f "$pidfile"
        fi
        ;;
      container:*)
        if [[ "$(_dk_host_docker inspect -f '{{.State.Running}}' "${target#container:}" 2>/dev/null || echo false)" == "true" ]]; then
          printf "  \033[32m●\033[0m localhost:%-6s (container %s)\n" "$port" "${target#container:}"
          found=1
        else
          rm -f "$pidfile"
        fi
        ;;
      *)
        rm -f "$pidfile"
        ;;
    esac
  done
  [[ "$found" -eq 0 ]] && _info "No ports forwarded. Use: cac docker port <port>"
}

_dk_port_stop_all() {
  mkdir -p "$_dk_port_dir"
  for pidfile in "$_dk_port_dir"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local target
    target=$(cat "$pidfile" 2>/dev/null || true)
    case "$target" in
      pid:*)
        kill "${target#pid:}" 2>/dev/null || true
        ;;
      container:*)
        _dk_host_docker rm -f "${target#container:}" >/dev/null 2>&1 || true
        ;;
    esac
    rm -f "$pidfile"
  done
}

_dk_run_cac_check() {
  local out="/tmp/cac-docker-check.out"
  local rc="/tmp/cac-docker-check.rc"
  local status=""

  _dk_compose exec -T "$_dk_service" sh -lc "rm -f '$out' '$rc'; (cac-check >'$out' 2>&1; printf '%s' \$? >'$rc') &" >/dev/null

  local i
  for i in $(seq 1 60); do
    status=$(_dk_compose exec -T "$_dk_service" sh -lc "test -f '$rc' && cat '$rc'" 2>/dev/null || true)
    [[ -n "$status" ]] && break
    sleep 1
  done

  _dk_compose exec -T "$_dk_service" sh -lc "test -f '$out' && cat '$out'" 2>/dev/null || true
  [[ -n "$status" ]] || { _err "cac-check did not finish"; return 1; }
  [[ "$status" == "0" ]]
}

# ── Docker subcommands ───────────────────────────────────────────────

_dk_cmd_setup() {
  _dk_init || return 1
  echo ""
  printf "\033[1mcac docker setup\033[0m\n"
  echo ""

  local proxy mode detected_mode docker_dir data_dir container_name runtime_hostname gateway_name child_proxy child_no_proxy derived_child_proxy image_ref ssh_enabled ssh_port ssh_password
  proxy=$(_dk_prompt_value "Proxy URI (SOCKS5 compact host:port or explicit http:// / socks5h://)" "$(_dk_read_env PROXY_URI)" 1) || return 1

  detected_mode=$(_dk_detect_mode)
  mode="$detected_mode"
  proxy="$(_dk_normalize_proxy_uri "$mode" "$proxy")"
  if [[ "$proxy" != "$(_dk_read_env PROXY_URI)" ]]; then
    case "$proxy" in
      host.docker.internal:*|*://*host.docker.internal:*)
        _info "Local Docker mode detected, using \033[1m${proxy}\033[0m for host-side proxy access"
        ;;
    esac
  fi
  _dk_write_env PROXY_URI "$proxy"
  _dk_write_env DEPLOY_MODE "$mode"

  echo ""
  if [[ "$mode" == "local" ]]; then
    _info "Detected: \033[1mlocal laptop\033[0m (Docker Desktop)"
    _info "Mode: bridge network — main container isolated, child containers use host Docker"
    _dk_delete_env_keys HOST_INTERFACE MACVLAN_SUBNET MACVLAN_GATEWAY MACVLAN_IP SHIM_IP
  else
    _info "Detected: \033[1mremote server\033[0m (native Linux Docker)"
    _info "Mode: macvlan — main container isolated from host, child containers use host Docker"
    echo ""
    _info "Detecting network..."
    if ! _dk_detect_network; then
      _warn "Auto-detect failed, enter the required remote network values"
      _dk_write_env HOST_INTERFACE "$(_dk_prompt_value "Host interface" "$(_dk_read_env HOST_INTERFACE)" 1)" || return 1
      _dk_write_env MACVLAN_SUBNET "$(_dk_prompt_value "Macvlan subnet (CIDR)" "$(_dk_read_env MACVLAN_SUBNET)" 1)" || return 1
      _dk_write_env MACVLAN_GATEWAY "$(_dk_prompt_value "Macvlan gateway" "$(_dk_read_env MACVLAN_GATEWAY)" 1)" || return 1
      _dk_write_env MACVLAN_IP "$(_dk_prompt_value "Container IP" "$(_dk_read_env MACVLAN_IP)" 1)" || return 1
      _dk_write_env SHIM_IP "$(_dk_prompt_value "Shim IP" "$(_dk_read_env SHIM_IP)" 1)" || return 1
    fi
  fi

  echo ""
  data_dir="${CAC_DATA:-$(_dk_read_env CAC_DATA)}"
  data_dir="${data_dir:-./data}"
  container_name="${CAC_CONTAINER_NAME:-$(_dk_read_env CAC_CONTAINER_NAME)}"
  container_name="${container_name:-boris-main}"
  runtime_hostname="${CAC_CONTAINER_RUNTIME_HOSTNAME:-$(_dk_read_env CAC_CONTAINER_RUNTIME_HOSTNAME)}"
  runtime_hostname="${runtime_hostname:-$container_name}"
  gateway_name="${CAC_DOCKER_PROXY_NAME:-$(_dk_read_env CAC_DOCKER_PROXY_NAME)}"
  gateway_name="${gateway_name:-boris-gateway}"
  ssh_enabled="${CAC_ENABLE_SSH:-$(_dk_read_env CAC_ENABLE_SSH)}"
  ssh_enabled="${ssh_enabled:-1}"
  ssh_port="${CAC_HOST_SSH_PORT:-$(_dk_read_env CAC_HOST_SSH_PORT)}"
  ssh_port="${ssh_port:-2222}"
  ssh_password="${CAC_SSH_PASSWORD:-$(_dk_read_env CAC_SSH_PASSWORD)}"
  ssh_password="${ssh_password:-cherny}"
  image_ref="${CAC_DOCKER_IMAGE:-$(_dk_read_env CAC_DOCKER_IMAGE)}"
  if [[ -z "$image_ref" ]]; then
    image_ref="$(_dk_default_image_ref)"
  elif ! _dk_is_pinned_image_ref "$image_ref"; then
    if [[ -n "${CAC_DOCKER_IMAGE:-}" ]]; then
      _err "CAC_DOCKER_IMAGE must be pinned to an exact tag or digest, not '$image_ref'"
      return 1
    fi
    _warn "Replacing mutable Docker image ref '$image_ref' with pinned default '$(_dk_default_image_ref)'"
    image_ref="$(_dk_default_image_ref)"
  fi
  derived_child_proxy="$(_dk_guess_child_proxy_url "$mode" "$proxy")"
  child_proxy="${derived_child_proxy:-${CAC_CHILD_CONTAINER_PROXY_URL:-$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)}}"
  child_no_proxy="${CAC_CHILD_CONTAINER_NO_PROXY:-$(_dk_read_env CAC_CHILD_CONTAINER_NO_PROXY)}"
  child_no_proxy="${child_no_proxy:-$(_dk_default_child_no_proxy "$mode")}"

  docker_dir=$(_docker_dir)
  if [[ "$data_dir" == /* ]]; then
    mkdir -p "${data_dir}/root" "${data_dir}/home"
  else
    mkdir -p "${docker_dir}/${data_dir#./}/root" "${docker_dir}/${data_dir#./}/home"
  fi

  _dk_write_env CAC_DATA "$data_dir"
  _dk_write_env CAC_CONTAINER_NAME "$container_name"
  _dk_write_env CAC_CONTAINER_RUNTIME_HOSTNAME "$runtime_hostname"
  _dk_write_env CAC_DOCKER_IMAGE "$image_ref"
  _dk_write_env CAC_DOCKER_BUILD_LOCAL "${CAC_DOCKER_BUILD_LOCAL:-0}"
  _dk_write_env CAC_CHILD_CONTAINER_NETWORK_MODE "bridge"
  _dk_write_env CAC_DOCKER_PROXY_NAME "$gateway_name"
  _dk_write_env CAC_DOCKER_PROXY_IP "172.31.255.2"
  _dk_write_env CAC_DOCKER_CLIENT_IP "172.31.255.3"
  _dk_write_env CAC_DOCKER_CONTROL_SUBNET "172.31.255.0/24"
  _dk_write_env CAC_CONTAINER_DOCKER_HOST "tcp://${gateway_name}:2375"
  _dk_write_env CAC_CHILD_CONTAINER_PROXY_URL "$child_proxy"
  _dk_write_env CAC_CHILD_CONTAINER_NO_PROXY "$child_no_proxy"
  _dk_write_env CAC_ENABLE_SSH "$ssh_enabled"
  _dk_write_env CAC_HOST_SSH_PORT "$ssh_port"
  _dk_write_env CAC_SSH_PASSWORD "$ssh_password"
  if [[ -f "$_dk_env_file" ]]; then
    local cleanup_tmp
    cleanup_tmp=$(mktemp)
    grep -v -E '^(DOCKER_HOST|CAC_WORKSPACE_HOST)=' "$_dk_env_file" > "$cleanup_tmp" && mv "$cleanup_tmp" "$_dk_env_file"
  fi

  _ok "Config saved"
  echo ""
  _info "Proxy: \033[1m${proxy}\033[0m"
  _info "Mode: \033[1m${mode}\033[0m"
  _info "Data dir: \033[1m${data_dir}\033[0m"
  _info "Image: \033[1m${image_ref}\033[0m"
  if _dk_wants_local_build; then
    _info "Build mode: \033[1mlocal source build\033[0m"
  else
    _info "Build mode: \033[1mpinned image pull\033[0m"
  fi
  _info "Container: \033[1m${container_name}\033[0m (hostname: ${runtime_hostname})"
  [[ -n "$child_proxy" ]] && _info "Child proxy: \033[1m${child_proxy}\033[0m"
  if [[ "$ssh_enabled" != "0" ]]; then
    _info "SSH: \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
  fi
  _info "Workspace mount: \033[1m$(_dk_workspace_host_abs)\033[0m → /workspace (current directory at start time)"
  _info "Container Docker API: \033[1mtcp://${gateway_name}:2375\033[0m (via docker-proxy sidecar)"
  _info "Next: \033[1mcac docker create\033[0m"
}

_dk_cmd_create() {
  _dk_init || return 1
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  echo ""
  if _dk_should_build_local; then
    _dk_build_runtime_image_locally || return 1
  else
    _dk_prepare_pinned_runtime_image || return 1
  fi
  echo ""
  _dk_assert_docker_cli_compat || return 1
  _ok "Image ready"
  _info "Start with: \033[1mcac docker start\033[0m"
}

_dk_cmd_start() {
  _dk_init || return 1
  local ssh_enabled ssh_port
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  _dk_load_env
  _dk_assert_docker_cli_compat || return 1
  _info "Starting container..."
  if _dk_should_build_local; then
    if _dk_force_local_rebuild; then
      _info "Rebuilding local images first..."
      _dk_compose up -d --build
    elif ! _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
      _info "Local image missing, building first..."
      _dk_compose up -d --build
    else
      _dk_compose up -d
    fi
  else
    if ! _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
      _dk_prepare_pinned_runtime_image || return 1
    fi
    _dk_compose up -d
  fi
  _dk_shim_up

  local state
  if _dk_wait_runtime_ready; then
    state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "unknown")
    ssh_enabled="${CAC_ENABLE_SSH:-$(_dk_read_env CAC_ENABLE_SSH)}"
    ssh_enabled="${ssh_enabled:-1}"
    ssh_port="${CAC_HOST_SSH_PORT:-$(_dk_read_env CAC_HOST_SSH_PORT)}"
    ssh_port="${ssh_port:-2222}"
    _ok "Container running"
    _info "Enter with:   \033[1mcac docker enter\033[0m"
    _info "Check with:   \033[1mcac docker check\033[0m"
    if [[ "$ssh_enabled" != "0" ]]; then
      _info "SSH with:     \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
    fi
    _info "Forward port: \033[1mcac docker port <port>\033[0m"
    _info "Workspace:    \033[1m/workspace\033[0m (host: $(_dk_workspace_host_current 2>/dev/null || echo unset))"
  else
    state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "unknown")
    _err "Container state: $state"
    _dk_abort_startup
    _info "Logs: cac docker logs"
    return 1
  fi
}

_dk_cmd_stop() {
  _dk_init || return 1
  _dk_port_stop_all
  _dk_shim_down
  _info "Stopping container..."
  _dk_compose down
  _ok "Stopped"
}

_dk_cmd_restart() {
  _dk_cmd_stop
  _dk_cmd_start
}

_dk_cmd_rebuild() {
  _dk_init || return 1
  local state="not created"
  state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "not created")

  CAC_DOCKER_REBUILD=1 _dk_cmd_create || return 1

  echo ""
  if [[ "$state" == "running" || "$state" == "exited" || "$state" == "created" || "$state" == "restarting" ]]; then
    _info "Recreating existing container to use the rebuilt image..."
    _dk_compose up -d --force-recreate || return 1
    if _dk_wait_runtime_ready; then
      _ok "Container recreated with rebuilt image"
      _info "Next: \033[1mcac docker check\033[0m"
    else
      _err "Container did not finish initialization after rebuild"
      _dk_abort_startup
      _info "Logs: \033[1mcac docker logs\033[0m"
      return 1
    fi
  else
    _info "Next: \033[1mcac docker start\033[0m"
  fi
}

_dk_cmd_enter() {
  _dk_init || return 1
  _dk_compose exec -u "${CAC_FAKE_USER:-cherny}" "$_dk_service" bash
}

_dk_cmd_check() {
  _dk_init || return 1
  local rc=0 ssh_enabled ssh_port
  _dk_run_cac_check || rc=1
  ssh_enabled="${CAC_ENABLE_SSH:-$(_dk_read_env CAC_ENABLE_SSH)}"
  ssh_enabled="${ssh_enabled:-1}"
  ssh_port="${CAC_HOST_SSH_PORT:-$(_dk_read_env CAC_HOST_SSH_PORT)}"
  ssh_port="${ssh_port:-2222}"

  if [[ "$ssh_enabled" != "0" ]]; then
    printf "\033[1mHost Access\033[0m\n"
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "${ssh_port}" >/dev/null 2>&1; then
      _ok "SSH: \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
    elif python3 - "$ssh_port" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.close()
PY
    then
      _ok "SSH: \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
    else
      _err "SSH port 127.0.0.1:${ssh_port} is not reachable"
      rc=1
    fi
    echo ""
  fi

  echo ""
  printf "\033[1mExit IP Comparison\033[0m\n"
  echo ""

  local container_ip
  container_ip=$(_dk_compose exec -T "$_dk_service" timeout 10 curl -sf https://ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$container_ip" ]]; then
    _ok "Container exit: \033[1m${container_ip}\033[0m"
  else
    _err "Container cannot reach ifconfig.me"
  fi

  local host_ip
  host_ip=$(timeout 10 curl -sf https://ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$host_ip" ]]; then
    _ok "Host exit:      \033[1m${host_ip}\033[0m"
  else
    _info "Host cannot reach ifconfig.me (blocked or no proxy — this is fine)"
  fi

  echo ""
  if [[ -n "$container_ip" && -n "$host_ip" ]]; then
    if [[ "$container_ip" != "$host_ip" ]]; then
      _ok "Exit IPs differ — container uses a different network path than host"
    else
      _info "Exit IPs are the same — verify \033[1m${container_ip}\033[0m is your proxy's exit IP"
    fi
  elif [[ -n "$container_ip" && -z "$host_ip" ]]; then
    _ok "Container can reach internet, host cannot — proxy is working"
  fi
  echo ""
  return "$rc"
}

_dk_cmd_port() {
  _dk_init || return 1
  local subcmd="${1:-}" port="${2:-}"
  case "$subcmd" in
    ""|ls|list)   _dk_port_list ;;
    stop)
      if [[ -z "$port" ]]; then
        _dk_port_stop_all; _ok "All port forwarders stopped"
      else
        _dk_port_stop "$port"
      fi ;;
    [0-9]*)       _dk_port_forward "$subcmd" ;;
    *)
      echo "Usage:"
      echo "  cac docker port <port>       Forward localhost:port to container"
      echo "  cac docker port list         List active forwarders"
      echo "  cac docker port stop [port]  Stop forwarder(s)" ;;
  esac
}

_dk_cmd_logs() {
  _dk_init || return 1
  _dk_compose logs --tail=50 -f "$_dk_service"
}

_dk_cmd_status() {
  _dk_init || return 1
  _dk_load_env
  echo ""
  printf "\033[1mcac docker status\033[0m\n"
  echo ""

  printf "  Mode:       %s\n" "$(_dk_get_mode)"

  local proxy
  proxy=$(_dk_read_env PROXY_URI)
  if [[ -n "$proxy" ]]; then
    local dp
    if [[ "$proxy" == *"://"* ]]; then dp="${proxy%%://*}://***"
    else IFS=: read -r _h _p _rest <<< "$proxy"; dp="${_h}:${_p}:***"; fi
    printf "  Proxy:      %s\n" "$dp"
  else
    printf "  Proxy:      \033[33mnot configured\033[0m\n"
  fi

  if [[ "$(_dk_get_mode)" == "remote" ]]; then
    local cip; cip=$(_dk_read_env MACVLAN_IP)
    [[ -n "$cip" ]] && printf "  Container:  %s\n" "$cip"
  fi
  local workspace_host child_net docker_host child_proxy ssh_enabled ssh_port
  workspace_host=$(_dk_workspace_host_current 2>/dev/null || echo "")
  child_net=$(_dk_read_env CAC_CHILD_CONTAINER_NETWORK_MODE)
  docker_host=$(_dk_read_env CAC_CONTAINER_DOCKER_HOST)
  child_proxy=$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)
  ssh_enabled=$(_dk_read_env CAC_ENABLE_SSH)
  ssh_enabled="${ssh_enabled:-1}"
  ssh_port=$(_dk_read_env CAC_HOST_SSH_PORT)
  ssh_port="${ssh_port:-2222}"
  [[ -n "$workspace_host" ]] && printf "  Workspace:  %s -> /workspace\n" "$workspace_host"
  [[ -n "$docker_host" ]] && printf "  Container Docker API: %s\n" "$docker_host"
  [[ -n "$child_net" ]] && printf "  Child net:  %s\n" "$child_net"
  [[ -n "$child_proxy" ]] && printf "  Child proxy:%s\n" " $child_proxy"
  [[ "$ssh_enabled" != "0" ]] && printf "  SSH:        ssh -p %s %s@127.0.0.1\n" "$ssh_port" "${CAC_FAKE_USER:-cherny}"

  local state
  state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "not created")
  case "$state" in
    running) printf "  Status:     \033[32mrunning\033[0m\n" ;;
    *)       printf "  Status:     \033[33m%s\033[0m\n" "$state" ;;
  esac

  local health
  health=$(_dk_compose ps --format '{{.Health}}' "$_dk_service" 2>/dev/null || echo "")
  [[ -n "$health" ]] && printf "  Health:     %s\n" "$health"

  echo ""
  printf "\033[1mPorts\033[0m\n"
  _dk_port_list
  echo ""
}

_dk_cmd_destroy() {
  _dk_init || return 1
  read -rp "Remove container and image? [y/N]: " confirm
  if [[ "$confirm" == [yY] ]]; then
    _dk_port_stop_all
    _dk_shim_down
    _dk_compose down --rmi local --volumes 2>/dev/null || true
    _ok "Removed"
  fi
}

# ── Docker command dispatcher ────────────────────────────────────────

cmd_docker() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    setup)    _dk_cmd_setup ;;
    create)   _dk_cmd_create ;;
    rebuild)  _dk_cmd_rebuild ;;
    start)    _dk_cmd_start ;;
    stop)     _dk_cmd_stop ;;
    restart)  _dk_cmd_restart ;;
    enter)    _dk_cmd_enter ;;
    check)    _dk_cmd_check ;;
    port)     _dk_cmd_port "$@" ;;
    status)   _dk_cmd_status ;;
    logs)     _dk_cmd_logs ;;
    destroy)  _dk_cmd_destroy ;;
    help|-h|--help|"")
      echo ""
      printf "\033[1mUsage:\033[0m cac docker <command>\n"
      echo ""
      printf "\033[1mLifecycle:\033[0m\n"
      echo "  setup               Configure proxy (interactive)"
      echo "  create              Build/pull the Docker image"
      echo "  rebuild             Force-rebuild the Docker image"
      echo "  start               Start the container"
      echo "  stop                Stop the container"
      echo "  restart             Restart the container"
      echo "  destroy             Remove container and image"
      echo ""
      printf "\033[1mUse:\033[0m\n"
      echo "  enter               Open a shell (claude + cac ready)"
      echo "  port <port>         Forward localhost:port to container"
      echo "  port list           List active port forwarders"
      echo "  port stop [port]    Stop port forwarder(s)"
      echo ""
      printf "\033[1mDiagnostics:\033[0m\n"
      echo "  check               Network + identity diagnostics"
      echo "  status              Show config, state, and ports"
      echo "  logs                Follow container logs"
      echo "" ;;
    *)
      _err "Unknown docker command: $subcmd"
      cmd_docker help
      return 1 ;;
  esac
}
