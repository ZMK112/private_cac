# ── cac docker — port forwarding helpers ────────────────────────────

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
