# ── cac docker — 容器化部署管理 ─────────────────────────────────────

_info()  { printf '\033[36m▸\033[0m %b\n' "$*"; }
_ok()    { printf '\033[32m✓\033[0m %b\n' "$*"; }
_warn()  { printf '\033[33m!\033[0m %b\n' "$*"; }
_err()   { printf '\033[31m✗\033[0m %b\n' "$*" >&2; }

_docker_dir() {
  # Find docker/ relative to the cac script location
  local script_path
  script_path="$(command -v cac 2>/dev/null || echo "$0")"
  script_path="$(cd "$(dirname "$script_path")" && pwd)"

  # Check common locations
  for d in \
    "$script_path/docker" \
    "$script_path/../docker" \
    "$PWD/docker" \
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
_dk_image="ghcr.io/nmhjklnm/cac-docker:latest"
_dk_build_file="docker-compose.build.yml"

_dk_host_docker() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT docker "$@"
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
  if _dk_can_build_local; then
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
  local files workspace_host
  # shellcheck disable=SC2207  # intentional word splitting
  files=($(_dk_compose_files))
  workspace_host=$(_dk_workspace_host_abs) || return 1
  env -u DOCKER_HOST -u DOCKER_CONTEXT CAC_WORKSPACE_HOST="$workspace_host" \
    docker compose "${files[@]}" "$@"
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

  local proxy
  proxy=$(_dk_read_env PROXY_URI)
  if [[ -n "$proxy" ]]; then
    _info "Current proxy: \033[1m${proxy}\033[0m"
    read -rp "  New proxy URI (Enter to keep): " input
    [[ -n "$input" ]] && proxy="$input"
  else
    read -rp "  Proxy URI (e.g. ss://..., ip:port:user:pass): " proxy
  fi
  if [[ -z "$proxy" ]]; then
    _err "Proxy is required"
    return 1
  fi
  _dk_write_env PROXY_URI "$proxy"

  local mode
  mode=$(_dk_detect_mode)
  _dk_write_env DEPLOY_MODE "$mode"

  echo ""
  if [[ "$mode" == "local" ]]; then
    _info "Detected: \033[1mlocal laptop\033[0m (Docker Desktop)"
    _info "Mode: bridge network — main container isolated, child containers use host Docker"
  else
    _info "Detected: \033[1mremote server\033[0m (native Linux Docker)"
    _info "Mode: macvlan — main container isolated from host, child containers use host Docker"
    echo ""
    _info "Detecting network..."
    _dk_detect_network
  fi

  echo ""
  # Create persistent data directory
  local docker_dir
  docker_dir=$(_docker_dir)
  mkdir -p "${docker_dir}/data/root" "${docker_dir}/data/home"
  _dk_write_env CAC_CONTAINER_NAME "boris-main"
  _dk_write_env CAC_CONTAINER_RUNTIME_HOSTNAME "boris-main"
  _dk_write_env CAC_CHILD_CONTAINER_NETWORK_MODE "bridge"
  _dk_write_env CAC_DOCKER_PROXY_NAME "boris-gateway"
  _dk_write_env CAC_DOCKER_PROXY_IP "172.31.255.2"
  _dk_write_env CAC_DOCKER_CLIENT_IP "172.31.255.3"
  _dk_write_env CAC_DOCKER_CONTROL_SUBNET "172.31.255.0/24"
  _dk_write_env CAC_CONTAINER_DOCKER_HOST "tcp://boris-gateway:2375"
  if [[ -f "$_dk_env_file" ]]; then
    local cleanup_tmp
    cleanup_tmp=$(mktemp)
    grep -v -E '^(DOCKER_HOST|CAC_WORKSPACE_HOST)=' "$_dk_env_file" > "$cleanup_tmp" && mv "$cleanup_tmp" "$_dk_env_file"
  fi

  _ok "Config saved"
  echo ""
  _info "Workspace mount: \033[1m$(_dk_workspace_host_abs)\033[0m → /workspace (current directory at start time)"
  _info "Container Docker API: \033[1mtcp://boris-gateway:2375\033[0m (via docker-proxy sidecar)"
  _info "Next: \033[1mcac docker create\033[0m"
}

_dk_cmd_create() {
  _dk_init || return 1
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  echo ""
  if _dk_can_build_local; then
    if _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
      _info "Local image already present, refreshing docker-proxy..."
      _dk_compose build docker-proxy
    else
      _info "Building local images..."
      _dk_compose build
    fi
  else
    _info "Building docker-proxy image..."
    _dk_compose build docker-proxy
    _info "Pulling image..."
    _dk_host_docker pull "$_dk_image"
  fi
  echo ""
  _ok "Image ready"
  _info "Start with: \033[1mcac docker start\033[0m"
}

_dk_cmd_start() {
  _dk_init || return 1
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  _dk_load_env
  _info "Starting container..."
  if _dk_can_build_local; then
    if ! _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
      _info "Local image missing, building first..."
      _dk_compose up -d --build
    else
      _dk_compose up -d
    fi
  else
    _dk_compose up -d
  fi
  _dk_shim_up
  sleep 2

  local state
  state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "unknown")
  if [[ "$state" == "running" ]]; then
    _ok "Container running"
    _info "Enter with:   \033[1mcac docker enter\033[0m"
    _info "Check with:   \033[1mcac docker check\033[0m"
    _info "Forward port: \033[1mcac docker port <port>\033[0m"
    _info "Workspace:    \033[1m/workspace\033[0m (host: $(_dk_workspace_host_current 2>/dev/null || echo unset))"
  else
    _err "Container state: $state"
    _info "Logs: cac docker logs"
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

_dk_cmd_enter() {
  _dk_init || return 1
  _dk_compose exec -u "${CAC_FAKE_USER:-cherny}" "$_dk_service" bash
}

_dk_cmd_check() {
  _dk_init || return 1
  _dk_run_cac_check

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
  local workspace_host child_net docker_host child_proxy
  workspace_host=$(_dk_workspace_host_current 2>/dev/null || echo "")
  child_net=$(_dk_read_env CAC_CHILD_CONTAINER_NETWORK_MODE)
  docker_host=$(_dk_read_env CAC_CONTAINER_DOCKER_HOST)
  child_proxy=$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)
  [[ -n "$workspace_host" ]] && printf "  Workspace:  %s -> /workspace\n" "$workspace_host"
  [[ -n "$docker_host" ]] && printf "  Container Docker API: %s\n" "$docker_host"
  [[ -n "$child_net" ]] && printf "  Child net:  %s\n" "$child_net"
  [[ -n "$child_proxy" ]] && printf "  Child proxy:%s\n" " $child_proxy"

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
