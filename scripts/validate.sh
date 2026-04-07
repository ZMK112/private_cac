#!/usr/bin/env bash
set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT=""
CLI_HOME=""
DOCKER_WORKTREE=""
COMPOSE_PROJECT_NAME="cacvalidate$$"
CONTAINER_NAME=""
GATEWAY_NAME=""
IMAGE_NAME="cac-docker-validate:vlocal"
PROXY_PID=""
PROXY_PORT=""
SSH_PORT=""
WEB_PORT=""
CONTROL_SUBNET=""
RUN_DOCKER=true
KEEP_WORKDIR=false
STEP_INDEX=0
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

usage() {
  cat <<'EOF'
Usage: bash scripts/validate.sh [options]

Run repeatable local validation for cac, including Docker-mode smoke tests.

Options:
  --skip-docker      Run build/JS/CLI checks only
  --keep-workdir     Keep temp logs, HOME, and Docker worktree after exit
  --proxy-port PORT  Override the local SOCKS5 stub port
  --subnet CIDR      Override the validation Docker control subnet
  -h, --help         Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-docker)
        RUN_DOCKER=false
        shift
        ;;
      --keep-workdir)
        KEEP_WORKDIR=true
        shift
        ;;
      --proxy-port)
        [[ $# -ge 2 ]] || { echo "error: --proxy-port requires a value" >&2; exit 1; }
        PROXY_PORT="$2"
        shift 2
        ;;
      --subnet)
        [[ $# -ge 2 ]] || { echo "error: --subnet requires a value" >&2; exit 1; }
        CONTROL_SUBNET="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required tool '$1' not found" >&2
    exit 1
  }
}

mktemp_dir() {
  mktemp -d "/tmp/$1.XXXXXX"
}

sanitize_name() {
  echo "$1" | tr ' /:' '___' | tr -cd 'A-Za-z0-9._-'
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$1"
  if [[ -f "$2" ]]; then
    printf '       log: %s\n' "$2"
    sed -n '1,80p' "$2" | sed 's/^/       /'
  fi
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s\n' "$1"
}

run_step() {
  local name="$1"
  shift
  local safe_name
  safe_name="$(sanitize_name "$name")"
  local logfile="$LOG_ROOT/$(printf '%02d' "$STEP_INDEX")-${safe_name}.log"
  STEP_INDEX=$((STEP_INDEX + 1))
  if "$@" >"$logfile" 2>&1; then
    pass "$name"
    return 0
  fi
  fail "$name" "$logfile"
  return 1
}

capture_docker_debug() {
  [[ "$RUN_DOCKER" == "true" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  local label="${1:-docker-debug}"
  local debug_log="$LOG_ROOT/docker-debug.log"
  {
    echo "=== ${label} ==="
    echo "-- docker ps -a --"
    docker ps -a --format '{{.Names}} {{.Status}}' || true
    if [[ -n "$CONTAINER_NAME" ]]; then
      echo "-- inspect ${CONTAINER_NAME} --"
      docker inspect --format '{{json .State}}' "$CONTAINER_NAME" || true
      echo "-- logs ${CONTAINER_NAME} --"
      docker logs --tail 120 "$CONTAINER_NAME" || true
    fi
    if [[ -n "$GATEWAY_NAME" ]]; then
      echo "-- inspect ${GATEWAY_NAME} --"
      docker inspect --format '{{json .State}}' "$GATEWAY_NAME" || true
      echo "-- logs ${GATEWAY_NAME} --"
      docker logs --tail 120 "$GATEWAY_NAME" || true
    fi
    echo
  } >>"$debug_log" 2>&1
}

cleanup() {
  if [[ -n "$PROXY_PID" ]] && kill -0 "$PROXY_PID" 2>/dev/null; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
  fi

  if [[ "$RUN_DOCKER" == "true" && -n "$DOCKER_WORKTREE" && -x "$DOCKER_WORKTREE/cac" ]]; then
    docker_cmd stop >/dev/null 2>&1 || true
    docker compose \
      -p "$COMPOSE_PROJECT_NAME" \
      -f "$DOCKER_WORKTREE/docker/docker-compose.yml" \
      -f "$DOCKER_WORKTREE/docker/docker-compose.build.yml" \
      -f "$DOCKER_WORKTREE/docker/docker-compose.local.yml" \
      down --remove-orphans >/dev/null 2>&1 || true
  fi

  if [[ "$KEEP_WORKDIR" != "true" ]]; then
    [[ -n "$CLI_HOME" ]] && rm -rf "$CLI_HOME"
    [[ -n "$DOCKER_WORKTREE" ]] && rm -rf "$DOCKER_WORKTREE"
    [[ -n "$LOG_ROOT" ]] && rm -rf "$LOG_ROOT"
  fi
}

trap cleanup EXIT

find_free_port() {
  if [[ -n "$PROXY_PORT" ]]; then
    echo "$PROXY_PORT"
    return 0
  fi
  random_free_port
}

random_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

pick_control_subnet() {
  if [[ -n "$CONTROL_SUBNET" ]]; then
    echo "$CONTROL_SUBNET"
    return 0
  fi

  require_tool docker
  local attempt oct2 oct3 subnet probe
  for attempt in $(seq 1 32); do
    oct2=$((20 + RANDOM % 10))
    oct3=$((10 + RANDOM % 200))
    subnet="172.${oct2}.${oct3}.0/24"
    probe="${COMPOSE_PROJECT_NAME}-probe-${attempt}"
    if docker network create --driver bridge --subnet "$subnet" "$probe" >/dev/null 2>&1; then
      docker network rm "$probe" >/dev/null 2>&1 || true
      echo "$subnet"
      return 0
    fi
  done
  echo "172.28.245.0/24"
}

docker_cmd() {
  (
    cd "$DOCKER_WORKTREE" || exit 1
    env \
      COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
      PATH="$DOCKER_WORKTREE:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}" \
      "$DOCKER_WORKTREE/cac" docker "$@"
  )
}

wait_for_tcp() {
  local host="$1" port="$2"
  local i
  for i in $(seq 1 50); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

prepare_fake_cli_home() {
  CLI_HOME="$(mktemp_dir cac-validate-home)"
  mkdir -p "$CLI_HOME/.cac/versions/9.9.9"
  cat > "$CLI_HOME/.cac/versions/9.9.9/claude" <<'EOF'
#!/usr/bin/env bash
echo "mock claude $*"
EOF
  chmod +x "$CLI_HOME/.cac/versions/9.9.9/claude"
  echo "9.9.9" > "$CLI_HOME/.cac/versions/.latest"
}

run_build_checks() {
  cd "$ROOT_DIR" || return 1
  local template_dir="$ROOT_DIR/docker/templates"
  local json_templates=(
    "$template_dir/cherny.identity.json"
    "$template_dir/cherny.env.json"
    "$template_dir/cherny.prompt.json"
    "$template_dir/cherny.telemetry.json"
  )
  local required_templates=(
    "${json_templates[@]}"
    "$template_dir/cherny.clash.yaml"
    "$template_dir/README.md"
  )

  local file
  for file in "${required_templates[@]}"; do
    [[ -f "$file" ]] || { echo "missing required docker template asset: $file" >&2; return 1; }
  done
  for file in "${json_templates[@]}"; do
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file"
  done

  bash build.sh
  node --check src/relay.js
  node --check src/fingerprint-hook.js
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s bash -S warning \
      src/utils.sh \
      src/cmd_*.sh \
      src/dns_block.sh \
      src/mtls.sh \
      src/templates.sh \
      src/main.sh \
      build.sh
  else
    echo "shellcheck not found; skipping lint" >&2
  fi
}

run_cli_smoke() {
  prepare_fake_cli_home
  env -i \
    HOME="$CLI_HOME" \
    PATH="$ROOT_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    SHELL=/bin/bash \
    "$ROOT_DIR/cac" env create smoke -c 9.9.9

  env -i \
    HOME="$CLI_HOME" \
    PATH="$CLI_HOME/.cac/bin:$ROOT_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    SHELL=/bin/bash \
    bash --noprofile --norc -c '
      test "$(cat "$HOME/.cac/current")" = smoke
      test -d "$HOME/.cac/envs/smoke/.claude"
      command -v claude | grep -q "$HOME/.cac/bin/claude"
      claude --version | grep -q "mock claude --version"
      "$HOME/.cac/bin/claude" --version | grep -q "mock claude --version"
    '
}

prepare_docker_worktree() {
  DOCKER_WORKTREE="$(mktemp_dir cac-validate-worktree)"
  rsync -a \
    --exclude '.git/' \
    --exclude 'dist/' \
    --exclude 'docker/data/' \
    "$ROOT_DIR/" "$DOCKER_WORKTREE/"
  mkdir -p "$DOCKER_WORKTREE/docker/data/root" "$DOCKER_WORKTREE/docker/data/home"

  PROXY_PORT="$(find_free_port)"
  SSH_PORT="$(random_free_port)"
  while [[ "$SSH_PORT" == "$PROXY_PORT" ]]; do
    SSH_PORT="$(random_free_port)"
  done
  WEB_PORT="$(random_free_port)"
  while [[ "$WEB_PORT" == "$PROXY_PORT" || "$WEB_PORT" == "$SSH_PORT" ]]; do
    WEB_PORT="$(random_free_port)"
  done
  CONTROL_SUBNET="$(pick_control_subnet)"
  CONTAINER_NAME="boris-validate-main-${COMPOSE_PROJECT_NAME}"
  GATEWAY_NAME="boris-validate-gateway-${COMPOSE_PROJECT_NAME}"

  cat > "$DOCKER_WORKTREE/docker/.env" <<EOF
PROXY_URI=host.docker.internal:${PROXY_PORT}
DEPLOY_MODE=local
CAC_CONTAINER_NAME=${CONTAINER_NAME}
CAC_CONTAINER_RUNTIME_HOSTNAME=${CONTAINER_NAME}
CAC_CHILD_CONTAINER_NETWORK_MODE=bridge
CAC_DOCKER_PROXY_NAME=${GATEWAY_NAME}
CAC_DOCKER_PROXY_IP=${CONTROL_SUBNET%0/24}2
CAC_DOCKER_CLIENT_IP=${CONTROL_SUBNET%0/24}3
CAC_DOCKER_CONTROL_SUBNET=${CONTROL_SUBNET}
CAC_CONTAINER_DOCKER_HOST=tcp://${GATEWAY_NAME}:2375
CAC_CHILD_CONTAINER_PROXY_URL=socks5h://host.docker.internal:${PROXY_PORT}
CAC_CHILD_CONTAINER_NO_PROXY=localhost,127.0.0.1,::1,host.docker.internal
CAC_DOCKER_IMAGE=${IMAGE_NAME}
CAC_DOCKER_BUILD_LOCAL=1
CAC_HOST_SSH_PORT=${SSH_PORT}
CAC_HOST_WEB_PORT=${WEB_PORT}
EOF
}

start_proxy_stub() {
  python3 "$DOCKER_WORKTREE/docker/dev-socks5.py" --host 0.0.0.0 --port "$PROXY_PORT" \
    >"$LOG_ROOT/proxy-stub.log" 2>&1 &
  PROXY_PID=$!
  wait_for_tcp 127.0.0.1 "$PROXY_PORT"
}

docker_create_step() {
  docker_cmd create
}

docker_start_step() {
  docker_cmd start
  local running
  running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ "$running" == "true" ]]
}

docker_status_step() {
  docker_cmd status | tee "$LOG_ROOT/docker-status.out"
  grep -q 'Status:.*running' "$LOG_ROOT/docker-status.out"
}

docker_web_ui_step() {
  local i
  wait_for_tcp 127.0.0.1 "$WEB_PORT" || return 1
  for i in $(seq 1 30); do
    if curl --max-time 5 -fsSI "http://127.0.0.1:${WEB_PORT}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  curl --max-time 5 -fsSI "http://127.0.0.1:${WEB_PORT}" >/dev/null || return 1

  for i in $(seq 1 30); do
    if docker exec "$CONTAINER_NAME" sh -lc 'curl --max-time 5 -fsSI http://127.0.0.1:3001 >/dev/null' >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  docker exec "$CONTAINER_NAME" sh -lc 'curl --max-time 5 -fsSI http://127.0.0.1:3001 >/dev/null' || return 1
}

docker_cac_check_step() {
  docker_cmd check
}

docker_container_check_step() {
  docker exec "$CONTAINER_NAME" cac-check
}

docker_child_wrapper_step() {
  local version_out child_out
  version_out="$(docker exec "$CONTAINER_NAME" docker version --format '{{.Server.Version}}')"
  [[ -n "$version_out" ]]
  child_out="$(
    docker exec "$CONTAINER_NAME" sh -lc \
      "docker run --rm --entrypoint sh -v /workspace:/mnt ${IMAGE_NAME} -lc 'test -d /mnt && printf \"%s\\n\" \"\$ALL_PROXY\"'"
  )"
  echo "$child_out" | grep -q "socks5h://host.docker.internal:${PROXY_PORT}"
}

docker_port_forward_step() {
  docker exec -d "$CONTAINER_NAME" sh -lc 'python3 -m http.server 6287 >/tmp/cac-validate-http.log 2>&1' || return 1
  sleep 1
  docker_cmd port 6287 || return 1
  sleep 1
  curl --max-time 5 -fsS "http://127.0.0.1:6287" >/dev/null || return 1
  docker_cmd port stop 6287 || return 1
}

docker_fail_closed_step() {
  [[ -n "$PROXY_PID" ]] || return 1
  kill "$PROXY_PID"
  wait "$PROXY_PID" 2>/dev/null || true
  PROXY_PID=""
  sleep 1
  if docker exec "$CONTAINER_NAME" sh -lc 'timeout 10 curl -fsS https://ifconfig.me >/dev/null'; then
    echo "container still has egress after proxy stop" >&2
    return 1
  fi
}

docker_stop_step() {
  docker_cmd stop
  ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"
}

print_summary() {
  echo
  echo "Validation summary"
  echo "  passes:   $PASS_COUNT"
  echo "  failures: $FAIL_COUNT"
  echo "  warnings: $WARN_COUNT"
  if [[ "$KEEP_WORKDIR" == "true" ]]; then
    [[ -n "$LOG_ROOT" ]] && echo "  logs:     $LOG_ROOT"
    [[ -n "$CLI_HOME" ]] && echo "  cli-home: $CLI_HOME"
    [[ -n "$DOCKER_WORKTREE" ]] && echo "  docker:   $DOCKER_WORKTREE"
  fi
}

main() {
  parse_args "$@"

  require_tool bash
  require_tool node
  require_tool python3
  require_tool rsync
  LOG_ROOT="$(mktemp_dir cac-validate-logs)"

  run_step "build-and-js-checks" run_build_checks || true
  run_step "cli-smoke" run_cli_smoke || true

  if [[ "$RUN_DOCKER" == "true" ]]; then
    require_tool docker
    require_tool curl
    prepare_docker_worktree
    run_step "proxy-stub" start_proxy_stub || true
    run_step "docker-create" docker_create_step || capture_docker_debug "docker-create"
    run_step "docker-start" docker_start_step || capture_docker_debug "docker-start"
    run_step "docker-status" docker_status_step || capture_docker_debug "docker-status"
    run_step "docker-web-ui" docker_web_ui_step || capture_docker_debug "docker-web-ui"
    run_step "docker-check-command" docker_cac_check_step || capture_docker_debug "docker-check-command"
    run_step "container-cac-check" docker_container_check_step || capture_docker_debug "container-cac-check"
    run_step "child-docker-wrapper" docker_child_wrapper_step || capture_docker_debug "child-docker-wrapper"
    run_step "docker-port-forward" docker_port_forward_step || capture_docker_debug "docker-port-forward"
    run_step "docker-fail-closed" docker_fail_closed_step || capture_docker_debug "docker-fail-closed"
    run_step "docker-stop" docker_stop_step || capture_docker_debug "docker-stop"
  fi

  print_summary
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
