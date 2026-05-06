# ── cac docker — runtime, subcommands, and dispatcher ───────────────

_dk_run_cac_check() {
  local out="/tmp/cac-docker-check.out"
  local rc="/tmp/cac-docker-check.rc"
  local status="" printed_lines=0 line_count=""

  _dk_compose exec -T "$_dk_service" sh -lc "rm -f '$out' '$rc'; (cac-check >'$out' 2>&1; printf '%s' \$? >'$rc') &" >/dev/null

  local i
  for i in $(seq 1 60); do
    line_count="$(
      _dk_compose exec -T "$_dk_service" sh -lc "test -f '$out' && wc -l < '$out'" 2>/dev/null |
        tr -d '\r\n'
    )"
    if [[ "$line_count" =~ ^[0-9]+$ ]] && (( line_count > printed_lines )); then
      _dk_compose exec -T "$_dk_service" sh -lc "sed -n '$((printed_lines + 1)),${line_count}p' '$out'" 2>/dev/null || true
      printed_lines=$line_count
    fi
    status=$(_dk_compose exec -T "$_dk_service" sh -lc "test -f '$rc' && cat '$rc'" 2>/dev/null || true)
    [[ -n "$status" ]] && break
    sleep 1
  done

  line_count="$(
    _dk_compose exec -T "$_dk_service" sh -lc "test -f '$out' && wc -l < '$out'" 2>/dev/null |
      tr -d '\r\n'
  )"
  if [[ "$line_count" =~ ^[0-9]+$ ]] && (( line_count > printed_lines )); then
    _dk_compose exec -T "$_dk_service" sh -lc "sed -n '$((printed_lines + 1)),${line_count}p' '$out'" 2>/dev/null || true
  fi
  [[ -n "$status" ]] || { _err "cac-check did not finish"; return 1; }
  [[ "$status" == "0" ]]
}

# ── Docker subcommands ───────────────────────────────────────────────

_dk_cmd_setup() {
  _dk_init || return 1
  echo ""
  printf "\033[1mcac docker setup\033[0m\n"
  echo ""

  local proxy mode detected_mode docker_dir data_dir prior_data_dir data_dir_abs prior_data_dir_abs data_state_summary container_name runtime_hostname gateway_name child_proxy child_no_proxy image_ref ssh_enabled ssh_port ssh_password web_enabled web_port web_bind current_state prior_proxy proxy_changed=0 proxy_probe_ok=0 running_workspace new_workspace preferred_shell shell_choice shell_changed=0 data_dir_changed=0 restart_reason="saved settings" control_subnet proxy_ip client_ip bridge_ip
  prior_proxy="$(_dk_read_env PROXY_URI)"
  current_state="$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "not created")"
  proxy=$(_dk_prompt_value "Proxy URI (host:port, http:// / socks5h://, or share links socks:// / ss:// / vmess:// / vless:// / trojan://)" "$prior_proxy" 1) || return 1

  detected_mode=$(_dk_detect_mode)
  mode="$detected_mode"
  proxy="$(_dk_normalize_proxy_uri "$mode" "$proxy")"
  if [[ "$proxy" != "$prior_proxy" ]]; then
    proxy_changed=1
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
  prior_data_dir="$(_dk_read_env CAC_DATA)"
  prior_data_dir="${prior_data_dir:-./data}"
  data_dir="${CAC_DATA:-$prior_data_dir}"
  data_dir="${data_dir:-./data}"
  prior_data_dir_abs="$(_dk_data_dir_abs "$prior_data_dir")"
  data_dir_abs="$(_dk_data_dir_abs "$data_dir")"
  if [[ "$data_dir_abs" != "$prior_data_dir_abs" ]]; then
    data_dir_changed=1
    echo ""
    _warn "Changing \033[1mCAC_DATA\033[0m switches the persisted Claude state location."
    _info "Current data path: \033[1m${prior_data_dir_abs}\033[0m"
    _info "Requested data path: \033[1m${data_dir_abs}\033[0m"
    if _dk_claude_state_detected "$prior_data_dir_abs"; then
      _warn "Existing Claude login/session data was detected in the current data directory."
    else
      _info "No Claude state was detected in the current data directory."
    fi
    if _dk_claude_state_detected "$data_dir_abs"; then
      _warn "Claude state was also detected in the requested data directory."
    else
      _info "No Claude state was detected in the requested data directory yet."
    fi
    if ! _dk_prompt_yes_no "Switch Docker data storage to the new directory?" "N"; then
      _warn "Aborted to avoid switching Claude state directories implicitly."
      return 1
    fi
  fi
  data_state_summary="$(_dk_claude_state_summary "$data_dir_abs")"
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
  web_enabled="${CAC_ENABLE_WEB:-$(_dk_read_env CAC_ENABLE_WEB)}"
  web_enabled="${web_enabled:-1}"
  web_port="${CAC_HOST_WEB_PORT:-$(_dk_read_env CAC_HOST_WEB_PORT)}"
  web_port="${web_port:-3001}"
  web_bind="${CAC_HOST_WEB_BIND:-$(_dk_read_env CAC_HOST_WEB_BIND)}"
  web_bind="${web_bind:-0.0.0.0}"
  ssh_password="${CAC_SSH_PASSWORD:-$(_dk_read_env CAC_SSH_PASSWORD)}"
  ssh_password="${ssh_password:-cherny}"
  preferred_shell="${CAC_FAKE_SHELL:-$(_dk_read_env CAC_FAKE_SHELL)}"
  preferred_shell="${preferred_shell:-/bin/zsh}"
  shell_choice="$(_dk_prompt_value "Default interactive shell (bash or zsh)" "${preferred_shell##*/}" 1)" || return 1
  case "$shell_choice" in
    bash|zsh)
      preferred_shell="/bin/${shell_choice}"
      ;;
    *)
      _err "Unsupported shell choice: ${shell_choice}"
      return 1
      ;;
  esac
  if [[ "$preferred_shell" != "$(_dk_read_env CAC_FAKE_SHELL)" ]]; then
    shell_changed=1
  fi
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
  _dk_prepare_child_proxy_bridge_env
  _dk_load_env
  control_subnet="${CAC_DOCKER_CONTROL_SUBNET:-$(_dk_read_env CAC_DOCKER_CONTROL_SUBNET)}"
  control_subnet="${control_subnet:-172.31.255.0/24}"
  proxy_ip="${CAC_DOCKER_PROXY_IP:-$(_dk_read_env CAC_DOCKER_PROXY_IP)}"
  proxy_ip="${proxy_ip:-$(_dk_control_ip_from_subnet "$control_subnet" 2)}"
  client_ip="${CAC_DOCKER_CLIENT_IP:-$(_dk_read_env CAC_DOCKER_CLIENT_IP)}"
  client_ip="${client_ip:-$(_dk_control_ip_from_subnet "$control_subnet" 3)}"
  bridge_ip="${CAC_CHILD_PROXY_BRIDGE_IP:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_IP)}"
  bridge_ip="${bridge_ip:-$(_dk_control_ip_from_subnet "$control_subnet" 4)}"
  child_proxy="${CAC_CHILD_CONTAINER_PROXY_URL:-$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)}"
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
  _dk_write_env CAC_DOCKER_PROXY_IP "$proxy_ip"
  _dk_write_env CAC_DOCKER_CLIENT_IP "$client_ip"
  _dk_write_env CAC_CHILD_PROXY_BRIDGE_IP "$bridge_ip"
  _dk_write_env CAC_DOCKER_CONTROL_SUBNET "$control_subnet"
  _dk_write_env CAC_CONTAINER_DOCKER_HOST "tcp://${gateway_name}:2375"
  _dk_write_env CAC_CHILD_CONTAINER_PROXY_URL "$child_proxy"
  _dk_write_env CAC_CHILD_CONTAINER_NO_PROXY "$child_no_proxy"
  _dk_write_env CAC_ENABLE_SSH "$ssh_enabled"
  _dk_write_env CAC_HOST_SSH_PORT "$ssh_port"
  _dk_write_env CAC_SSH_PASSWORD "$ssh_password"
  _dk_write_env CAC_FAKE_SHELL "$preferred_shell"
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
  _info "Data dir abs: \033[1m${data_dir_abs}\033[0m"
  _info "Claude state: \033[1m${data_state_summary}\033[0m"
  _info "Image: \033[1m${image_ref}\033[0m"
  if _dk_wants_local_build; then
    _info "Build mode: \033[1mlocal source build\033[0m"
  else
    _info "Build mode: \033[1mpinned image pull\033[0m"
  fi
  _info "Container: \033[1m${container_name}\033[0m (hostname: ${runtime_hostname})"
  _info "Shell: \033[1m${preferred_shell}\033[0m"
  [[ -n "$child_proxy" ]] && _info "Child proxy: \033[1m$(_dk_mask_proxy_display "$child_proxy")\033[0m"
  if [[ "$ssh_enabled" != "0" ]]; then
    _info "SSH: \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
  fi
  if [[ "$web_enabled" != "0" ]]; then
    _info "Web UI: \033[1mhttp://127.0.0.1:${web_port}\033[0m (bind: ${web_bind})"
  fi
  _info "Workspace mount: \033[1m$(_dk_workspace_host_abs)\033[0m → /workspace (current directory at start time)"
  _info "Container Docker API: \033[1mtcp://${gateway_name}:2375\033[0m (via docker-proxy sidecar)"
  _dk_warn_web_exposure
  echo ""
  if _dk_probe_proxy_uri "$proxy" "$mode"; then
    proxy_probe_ok=1
  else
    _warn "The new proxy was saved, but the quick probe failed."
    _info "The final runtime validation is still \033[1mcac docker check\033[0m."
  fi

  if [[ "$current_state" == "running" && ( "$proxy_changed" -eq 1 || "$shell_changed" -eq 1 || "$data_dir_changed" -eq 1 ) ]]; then
    echo ""
    running_workspace="$(_dk_workspace_host_current 2>/dev/null || true)"
    new_workspace="$(_dk_workspace_host_abs)"
    _warn "A Docker container is already running for this install."
    [[ -n "$running_workspace" ]] && _info "Current running workspace: \033[1m${running_workspace}\033[0m"
    _info "If you restart now from this shell, /workspace will mount: \033[1m${new_workspace}\033[0m"
    if [[ "$proxy_changed" -eq 1 && "$proxy_probe_ok" -eq 0 ]]; then
      _warn "Skipping automatic restart because the new proxy did not pass the quick check."
      _info "Saved only. Fix or verify the proxy first, then restart manually."
      return 0
    fi

    if [[ "$proxy_changed" -eq 1 && "$shell_changed" -eq 1 && "$data_dir_changed" -eq 1 ]]; then
      restart_reason="saved proxy, shell, and data directory"
    elif [[ "$proxy_changed" -eq 1 && "$data_dir_changed" -eq 1 ]]; then
      restart_reason="saved proxy and data directory"
    elif [[ "$shell_changed" -eq 1 && "$data_dir_changed" -eq 1 ]]; then
      restart_reason="saved shell and data directory"
    elif [[ "$proxy_changed" -eq 1 ]]; then
      restart_reason="saved proxy"
    elif [[ "$shell_changed" -eq 1 ]]; then
      restart_reason="saved shell"
    elif [[ "$data_dir_changed" -eq 1 ]]; then
      restart_reason="saved data directory"
    fi
    if _dk_prompt_yes_no "Restart the running Docker container now to apply the ${restart_reason}?" "N"; then
      _warn "Restarting now so the saved settings take effect..."
      _dk_cmd_restart || return 1
      echo ""
      _info "Next: \033[1mcac docker check\033[0m"
      return 0
    fi

    _info "Saved only. The running container keeps its current runtime state until you restart it manually."
    return 0
  fi

  _info "Next: \033[1mcac docker create\033[0m"
}

_dk_cmd_create() {
  _dk_init || return 1
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  _dk_load_env
  _dk_prepare_child_proxy_bridge_env
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
  local ssh_enabled ssh_port web_port current_state
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  _dk_load_env
  current_state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "not created")
  _dk_prepare_host_ports "$current_state" || return 1
  _dk_maybe_migrate_child_proxy
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
    if _dk_web_enabled; then
      web_port="$(_dk_web_port)"
      _info "Web UI:       \033[1mhttp://127.0.0.1:${web_port}\033[0m"
    fi
    _dk_warn_web_exposure
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
    _dk_load_env
    _dk_prepare_host_ports "$state" || return 1
    _dk_maybe_migrate_child_proxy
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
  local shell_path
  shell_path="${CAC_FAKE_SHELL:-$(_dk_read_env CAC_FAKE_SHELL)}"
  shell_path="${shell_path:-/bin/bash}"
  _dk_compose exec -u "${CAC_FAKE_USER:-cherny}" "$_dk_service" "$shell_path" -l
}

_dk_cmd_check() {
  _dk_init || return 1
  local rc=0 ssh_enabled ssh_port web_port
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

  if _dk_web_enabled; then
    web_port="$(_dk_web_port)"
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "${web_port}" >/dev/null 2>&1; then
      _ok "Web UI: \033[1mhttp://127.0.0.1:${web_port}\033[0m"
    elif python3 - "$web_port" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.close()
PY
    then
      _ok "Web UI: \033[1mhttp://127.0.0.1:${web_port}\033[0m"
    else
      _err "Web UI port 127.0.0.1:${web_port} is not reachable"
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
  local web_enabled web_port
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
  local workspace_host child_net docker_host child_proxy ssh_enabled ssh_port data_dir_raw data_dir_abs data_state_summary
  workspace_host=$(_dk_workspace_host_current 2>/dev/null || echo "")
  child_net=$(_dk_read_env CAC_CHILD_CONTAINER_NETWORK_MODE)
  docker_host=$(_dk_read_env CAC_CONTAINER_DOCKER_HOST)
  child_proxy=$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)
  ssh_enabled=$(_dk_read_env CAC_ENABLE_SSH)
  ssh_enabled="${ssh_enabled:-1}"
  ssh_port=$(_dk_read_env CAC_HOST_SSH_PORT)
  ssh_port="${ssh_port:-2222}"
  web_enabled=$(_dk_read_env CAC_ENABLE_WEB)
  web_enabled="${web_enabled:-1}"
  web_port=$(_dk_read_env CAC_HOST_WEB_PORT)
  web_port="${web_port:-3001}"
  data_dir_raw="$(_dk_data_dir_raw)"
  data_dir_abs="$(_dk_data_dir_abs "$data_dir_raw")"
  data_state_summary="$(_dk_claude_state_summary "$data_dir_abs")"
  printf "  Data dir:   %s\n" "$data_dir_raw"
  printf "  Data path:  %s\n" "$data_dir_abs"
  printf "  Claude:     %s\n" "$data_state_summary"
  [[ -n "$workspace_host" ]] && printf "  Workspace:  %s -> /workspace\n" "$workspace_host"
  [[ -n "$docker_host" ]] && printf "  Container Docker API: %s\n" "$docker_host"
  [[ -n "$child_net" ]] && printf "  Child net:  %s\n" "$child_net"
  [[ -n "$child_proxy" ]] && printf "  Child proxy:%s\n" " $(_dk_mask_proxy_display "$child_proxy")"
  [[ "$ssh_enabled" != "0" ]] && printf "  SSH:        ssh -p %s %s@127.0.0.1\n" "$ssh_port" "${CAC_FAKE_USER:-cherny}"
  [[ "$web_enabled" != "0" ]] && printf "  Web UI:     http://127.0.0.1:%s\n" "$web_port"

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
  _dk_warn_web_exposure
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
    ""|help|-h|--help)
      cat <<'EOF'
Usage: cac docker <subcommand>

  setup      Configure proxy and network (interactive)
  create     Build or pull the image
  rebuild    Force rebuild image and recreate container if needed
  start      Start the container
  stop       Stop the container
  restart    Restart the container
  enter      Shell into the container
  check      Diagnostics (network + identity)
  port       Forward a localhost port to the container
  status     Show current status
  logs       Follow container logs
  destroy    Remove container/network/images
EOF
      ;;
    *)
      _err "Unknown docker subcommand: $subcmd"
      _info "Use: cac docker help"
      return 1 ;;
  esac
}
