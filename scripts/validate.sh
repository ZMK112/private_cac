#!/usr/bin/env bash
set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT=""
CLI_HOME=""
DOCKER_WORKTREE=""
COMPOSE_PROJECT_NAME="cacvalidate$$"
CONTAINER_NAME=""
GATEWAY_NAME=""
BRIDGE_NAME=""
IMAGE_NAME=""
PROXY_PID=""
PROXY_PORT=""
SSH_PORT=""
WEB_PORT=""
BRIDGE_PORT=""
REQUESTED_SSH_PORT=""
REQUESTED_WEB_PORT=""
CONTROL_SUBNET=""
PORT_BLOCKER_PIDS=()
RUN_DOCKER=true
KEEP_WORKDIR=false
VALIDATE_SUITE="full"
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
  --suite NAME       Validation suite: fast | web | security | full
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
        VALIDATE_SUITE="fast"
        shift
        ;;
      --suite)
        [[ $# -ge 2 ]] || { echo "error: --suite requires a value" >&2; exit 1; }
        case "$2" in
          fast|web|security|full)
            VALIDATE_SUITE="$2"
            ;;
          *)
            echo "error: unknown suite: $2" >&2
            exit 1
            ;;
        esac
        shift 2
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

  if [[ "$VALIDATE_SUITE" == "fast" ]]; then
    RUN_DOCKER=false
  else
    RUN_DOCKER=true
  fi
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
  local heartbeat_after=30
  local heartbeat_every=30
  local start_ts last_heartbeat now rc heartbeat_pid
  STEP_INDEX=$((STEP_INDEX + 1))
  start_ts=$SECONDS
  last_heartbeat=0

  (
    while true; do
      sleep 1
      now=$((SECONDS - start_ts))
      if (( now >= heartbeat_after && now - last_heartbeat >= heartbeat_every )); then
        printf '[INFO] %s still running (%ss)\n' "$name" "$now"
        last_heartbeat=$now
      fi
    done
  ) &
  heartbeat_pid=$!

  if "$@" >"$logfile" 2>&1; then
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    pass "$name"
    return 0
  fi
  rc=$?
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true
  fail "$name" "$logfile"
  return "$rc"
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
    if [[ -n "$BRIDGE_NAME" ]]; then
      echo "-- inspect ${BRIDGE_NAME} --"
      docker inspect --format '{{json .State}}' "$BRIDGE_NAME" || true
      echo "-- logs ${BRIDGE_NAME} --"
      docker logs --tail 120 "$BRIDGE_NAME" || true
    fi
    echo
  } >>"$debug_log" 2>&1
}

cleanup() {
  local blocker_pid
  for blocker_pid in "${PORT_BLOCKER_PIDS[@]:-}"; do
    if [[ -n "$blocker_pid" ]] && kill -0 "$blocker_pid" 2>/dev/null; then
      kill "$blocker_pid" 2>/dev/null || true
      wait "$blocker_pid" 2>/dev/null || true
    fi
  done

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
    [[ -n "$IMAGE_NAME" ]] && docker image rm -f "$IMAGE_NAME" >/dev/null 2>&1 || true
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
  python3 scripts/cloudcli-upstream-audit.py --check
  python3 - <<'PY'
import json
import os
import sys

sys.path.insert(0, os.path.join(os.getcwd(), 'docker'))
from lib.protocols import parse
from lib.singbox import render_proxy_bridge

cases = [
    (
        'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@example.com:8388#demo',
        'shadowsocks',
        'example.com',
        8388,
    ),
    (
        'socks5://user:pass@example.com:1080',
        'socks',
        'example.com',
        1080,
    ),
    (
        'http://user:pass@example.com:8080',
        'http',
        'example.com',
        8080,
    ),
    (
        'socks://dXNlcjpwYXNz@example.com:1080#demo',
        'socks',
        'example.com',
        1080,
    ),
]

for uri, outbound_type, server, port in cases:
    proxy = parse(uri)
    config = render_proxy_bridge(
        proxy,
        listen_address='0.0.0.0',
        listen_port=17891,
        username='bridge',
        password='secret',
    )
    inbound = config['inbounds'][0]
    assert inbound['type'] == 'mixed'
    assert inbound['listen_port'] == 17891
    assert inbound['users'][0]['username'] == 'bridge'
    assert config['outbounds'][0]['type'] == outbound_type
    assert config['outbounds'][0]['server'] == server
    assert config['outbounds'][0]['server_port'] == port
PY
  bash -lc '
    source <(awk "
      /^proxy_env_url_for_disabled_singbox\\(\\)/ {flag=1}
      flag {print}
      flag && /^}/ {exit}
    " docker/entrypoint.sh)
    test "$(proxy_env_url_for_disabled_singbox "1.2.3.4:1080:user:pass")" = "socks5h://user:pass@1.2.3.4:1080"
    test "$(proxy_env_url_for_disabled_singbox "socks5://user:pass@1.2.3.4:1080")" = "socks5://user:pass@1.2.3.4:1080"
    test "$(proxy_env_url_for_disabled_singbox "http://user:pass@1.2.3.4:8080")" = "http://user:pass@1.2.3.4:8080"
    ! proxy_env_url_for_disabled_singbox "ss://example"
  '
  bash -lc '
    source src/cmd_docker.sh
    test "$(_dk_guess_build_proxy_url local "127.0.0.1:1080")" = "socks5h://host.docker.internal:1080"
    test "$(_dk_guess_build_proxy_url local "127.0.0.1:1080:user:pass")" = "socks5h://user:pass@host.docker.internal:1080"
    test "$(_dk_guess_build_proxy_url local "socks5h://user:pass@127.0.0.1:1080")" = "socks5h://user:pass@host.docker.internal:1080"
    test "$(_dk_canonicalize_proxy_uri "socks://dXNlcjpwYXNz@127.0.0.1:1080#demo")" = "socks5://user:pass@127.0.0.1:1080"
    test "$(_dk_normalize_proxy_uri local "socks://dXNlcjpwYXNz@127.0.0.1:1080#demo")" = "socks5://user:pass@host.docker.internal:1080"
    test "$(_dk_guess_build_proxy_url remote "http://user:pass@10.0.0.5:8080")" = "http://user:pass@10.0.0.5:8080"
    test -z "$(_dk_guess_build_proxy_url local "ss://example")"
  '
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
  REQUESTED_SSH_PORT="$SSH_PORT"
  REQUESTED_WEB_PORT="$WEB_PORT"
  CONTROL_SUBNET="$(pick_control_subnet)"
  IMAGE_NAME="cac-docker-validate:${COMPOSE_PROJECT_NAME}"
  CONTAINER_NAME="boris-validate-main-${COMPOSE_PROJECT_NAME}"
  GATEWAY_NAME="boris-validate-gateway-${COMPOSE_PROJECT_NAME}"
  BRIDGE_NAME="boris-validate-child-proxy-${COMPOSE_PROJECT_NAME}"

  cat > "$DOCKER_WORKTREE/docker/.env" <<EOF
PROXY_URI=host.docker.internal:${PROXY_PORT}
DEPLOY_MODE=local
CAC_CONTAINER_NAME=${CONTAINER_NAME}
CAC_CONTAINER_RUNTIME_HOSTNAME=${CONTAINER_NAME}
CAC_CHILD_CONTAINER_NETWORK_MODE=bridge
CAC_DOCKER_PROXY_NAME=${GATEWAY_NAME}
CAC_DOCKER_PROXY_IP=${CONTROL_SUBNET%0/24}2
CAC_DOCKER_CLIENT_IP=${CONTROL_SUBNET%0/24}3
CAC_CHILD_PROXY_BRIDGE_IP=${CONTROL_SUBNET%0/24}4
CAC_DOCKER_CONTROL_SUBNET=${CONTROL_SUBNET}
CAC_CONTAINER_DOCKER_HOST=tcp://${GATEWAY_NAME}:2375
CAC_CHILD_CONTAINER_PROXY_URL=socks5h://host.docker.internal:${PROXY_PORT}
CAC_CHILD_PROXY_BRIDGE_NAME=${BRIDGE_NAME}
CAC_CHILD_CONTAINER_NO_PROXY=localhost,127.0.0.1,::1,host.docker.internal
CAC_DOCKER_IMAGE=${IMAGE_NAME}
CAC_DOCKER_BUILD_LOCAL=1
CAC_HOST_SSH_PORT=${SSH_PORT}
CAC_HOST_WEB_PORT=${WEB_PORT}
CAC_FAKE_SHELL=/bin/bash
EOF
}

start_proxy_stub() {
  local -a args=(python3 "$DOCKER_WORKTREE/docker/dev-socks5.py" --host 0.0.0.0 --port "$PROXY_PORT")
  if [[ -n "${CAC_VALIDATE_UPSTREAM_PROXY:-}" ]]; then
    args+=(--upstream "$CAC_VALIDATE_UPSTREAM_PROXY")
  fi
  "${args[@]}" \
    >"$LOG_ROOT/proxy-stub.log" 2>&1 &
  PROXY_PID=$!
  wait_for_tcp 127.0.0.1 "$PROXY_PORT"
}

start_port_blocker() {
  local label="$1" port="$2" pid
  python3 -m http.server "$port" --bind 0.0.0.0 >"$LOG_ROOT/${label}-blocker.log" 2>&1 &
  pid=$!
  PORT_BLOCKER_PIDS+=("$pid")
  wait_for_tcp 127.0.0.1 "$port"
}

start_requested_port_blockers() {
  start_port_blocker ssh "$REQUESTED_SSH_PORT" || return 1
  start_port_blocker web "$REQUESTED_WEB_PORT" || return 1
}

load_actual_host_ports() {
  SSH_PORT="$(awk -F= '/^CAC_HOST_SSH_PORT=/{print $2}' "$DOCKER_WORKTREE/docker/.env" | tail -n1)"
  WEB_PORT="$(awk -F= '/^CAC_HOST_WEB_PORT=/{print $2}' "$DOCKER_WORKTREE/docker/.env" | tail -n1)"
  BRIDGE_PORT="$(awk -F= '/^CAC_CHILD_PROXY_BRIDGE_PORT=/{print $2}' "$DOCKER_WORKTREE/docker/.env" | tail -n1)"
  [[ -n "$SSH_PORT" && -n "$WEB_PORT" && -n "$BRIDGE_PORT" ]]
}

docker_create_step() {
  docker_cmd create
}

docker_start_step() {
  docker_cmd start
  load_actual_host_ports || return 1
  local running
  running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ "$running" == "true" ]]
}

docker_auto_port_step() {
  [[ "$SSH_PORT" != "$REQUESTED_SSH_PORT" ]] || {
    echo "ssh port did not move from occupied ${REQUESTED_SSH_PORT}" >&2
    return 1
  }
  [[ "$WEB_PORT" != "$REQUESTED_WEB_PORT" ]] || {
    echo "web port did not move from occupied ${REQUESTED_WEB_PORT}" >&2
    return 1
  }
  [[ "$SSH_PORT" -gt "$REQUESTED_SSH_PORT" ]] || {
    echo "ssh port ${SSH_PORT} did not advance past ${REQUESTED_SSH_PORT}" >&2
    return 1
  }
  [[ "$WEB_PORT" -gt "$REQUESTED_WEB_PORT" ]] || {
    echo "web port ${WEB_PORT} did not advance past ${REQUESTED_WEB_PORT}" >&2
    return 1
  }
  wait_for_tcp 127.0.0.1 "$SSH_PORT" || return 1
  wait_for_tcp 127.0.0.1 "$WEB_PORT" || return 1
}

docker_status_step() {
  docker_cmd status | tee "$LOG_ROOT/docker-status.out"
  grep -q 'Status:.*running' "$LOG_ROOT/docker-status.out"
}

docker_setup_proxy_switch_step() {
  local old_pid old_port old_container_id new_port new_pid expected_proxy actual_proxy new_container_id
  old_pid="$PROXY_PID"
  old_port="$PROXY_PORT"
  old_container_id="$(docker inspect --format '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ -n "$old_container_id" ]] || return 1

  new_port="$(random_free_port)"
  while [[ "$new_port" == "$old_port" || "$new_port" == "$SSH_PORT" || "$new_port" == "$WEB_PORT" || "$new_port" == "$BRIDGE_PORT" ]]; do
    new_port="$(random_free_port)"
  done

  local -a proxy_args=(python3 "$DOCKER_WORKTREE/docker/dev-socks5.py" --host 0.0.0.0 --port "$new_port")
  if [[ -n "${CAC_VALIDATE_UPSTREAM_PROXY:-}" ]]; then
    proxy_args+=(--upstream "$CAC_VALIDATE_UPSTREAM_PROXY")
  fi
  "${proxy_args[@]}" \
    >"$LOG_ROOT/proxy-switch-stub.log" 2>&1 &
  new_pid=$!
  wait_for_tcp 127.0.0.1 "$new_port" || {
    kill "$new_pid" 2>/dev/null || true
    wait "$new_pid" 2>/dev/null || true
    return 1
  }

  if ! printf '127.0.0.1:%s\n\ny\n' "$new_port" | docker_cmd setup; then
    kill "$new_pid" 2>/dev/null || true
    wait "$new_pid" 2>/dev/null || true
    return 1
  fi

  expected_proxy="socks5://host.docker.internal:${new_port}"
  actual_proxy="$(docker exec "$CONTAINER_NAME" sh -lc 'cat /home/cherny/.cac/envs/default/proxy' 2>/dev/null || true)"
  [[ "$actual_proxy" == "$expected_proxy" ]] || {
    kill "$new_pid" 2>/dev/null || true
    wait "$new_pid" 2>/dev/null || true
    echo "expected active proxy ${expected_proxy}, got ${actual_proxy:-<empty>}" >&2
    return 1
  }

  new_container_id="$(docker inspect --format '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ -n "$new_container_id" && "$new_container_id" != "$old_container_id" ]] || {
    kill "$new_pid" 2>/dev/null || true
    wait "$new_pid" 2>/dev/null || true
    echo "container was not recreated after proxy switch" >&2
    return 1
  }

  PROXY_PORT="$new_port"
  PROXY_PID="$new_pid"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    wait "$old_pid" 2>/dev/null || true
  fi
}

docker_shell_switch_step() {
  local actual_shell actual_shell_path
  if ! printf '127.0.0.1:%s\nzsh\ny\n' "$PROXY_PORT" | docker_cmd setup; then
    return 1
  fi

  actual_shell="$(docker exec "$CONTAINER_NAME" sh -lc 'getent passwd cherny | cut -d: -f7' 2>/dev/null || true)"
  [[ "$actual_shell" == "/bin/zsh" ]] || {
    echo "expected passwd shell /bin/zsh, got ${actual_shell:-<empty>}" >&2
    return 1
  }

  actual_shell_path="$(docker exec "$CONTAINER_NAME" sh -lc 'cat /home/cherny/.cac/envs/default/shell_path' 2>/dev/null || true)"
  [[ "$actual_shell_path" == "/bin/zsh" ]] || {
    echo "expected shell_path /bin/zsh, got ${actual_shell_path:-<empty>}" >&2
    return 1
  }
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

docker_web_nologin_step() {
  local auth_user_json projects_json
  auth_user_json="$(curl --max-time 10 -fsS "http://127.0.0.1:${WEB_PORT}/api/auth/user")" || return 1
  AUTH_USER_JSON="$auth_user_json" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["AUTH_USER_JSON"])
user = payload.get("user") or {}
if not user.get("username"):
    raise SystemExit("missing username in unauthenticated /api/auth/user response")
PY

  projects_json="$(curl --max-time 10 -fsS "http://127.0.0.1:${WEB_PORT}/api/projects")" || return 1
  PROJECTS_JSON="$projects_json" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PROJECTS_JSON"])
if not isinstance(payload, list):
    raise SystemExit("/api/projects did not return a JSON list")
PY

  docker exec "$CONTAINER_NAME" sh -lc \
    'chromium --headless --no-sandbox --disable-gpu --lang=en-US --virtual-time-budget=8000 --dump-dom http://127.0.0.1:3001' \
    >"$LOG_ROOT/cloudcli-dom.html" || return 1

  rg -q 'No projects found|Loading projects|Fetching your Claude projects and sessions' "$LOG_ROOT/cloudcli-dom.html" || return 1
  if rg -qi 'type="password"|login|create your account|sign in' "$LOG_ROOT/cloudcli-dom.html"; then
    echo "login UI still visible in platform mode" >&2
    return 1
  fi
}

ensure_web_project() {
  local projects_json project_json display_name
  projects_json="$(curl --max-time 10 -fsS "http://127.0.0.1:${WEB_PORT}/api/projects")" || return 1
  display_name="$(
    PROJECTS_JSON="$projects_json" python3 - <<'PY'
import json, os

projects = json.loads(os.environ["PROJECTS_JSON"])
for project in projects:
    if project.get("fullPath") == "/workspace" or project.get("path") == "/workspace":
        print(project.get("displayName") or project.get("name") or "workspace")
        break
PY
  )"

  if [[ -n "$display_name" ]]; then
    printf '%s\n' "$display_name"
    return 0
  fi

  project_json="$(curl --max-time 10 -fsS -X POST -H 'Content-Type: application/json' \
    -d '{"path":"/workspace"}' "http://127.0.0.1:${WEB_PORT}/api/projects/create")" || return 1
  PROJECT_JSON="$project_json" python3 - <<'PY'
import json, os, sys

payload = json.loads(os.environ["PROJECT_JSON"])
project = payload.get("project") or {}
name = project.get("displayName") or project.get("name") or "workspace"
sys.stdout.write(name)
PY
}

docker_web_disconnect_step() {
  local project_display_name
  project_display_name="$(ensure_web_project)" || return 1

  docker exec "$CONTAINER_NAME" node - "$WEB_PORT" "$project_display_name" <<'NODE'
const port = process.argv[2];
const projectName = process.argv[3];

(async () => {
  const { chromium } = require('playwright');
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.CHROME_PATH || '/usr/bin/chromium',
    args: ['--no-sandbox', '--disable-gpu'],
  });

  try {
    const page = await browser.newPage({ locale: 'en-US' });
    const baseUrl = `http://127.0.0.1:${port}`;

    await page.goto(baseUrl, { waitUntil: 'networkidle', timeout: 30000 });
    await page.getByText(projectName, { exact: true }).first().click({ timeout: 20000 });
    await page.getByRole('button', { name: 'Shell' }).click({ timeout: 10000 });

    const disconnectButton = page.getByRole('button', { name: 'Disconnect' });
    const connectButton = page.getByRole('button', { name: 'Continue in Shell' });

    await disconnectButton.waitFor({ state: 'visible', timeout: 20000 });
    await disconnectButton.click();
    await connectButton.waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(3000);

    if (await disconnectButton.isVisible().catch(() => false)) {
      throw new Error('Disconnect button became visible again without a manual reconnect');
    }
    if (!(await connectButton.isVisible().catch(() => false))) {
      throw new Error('Connect button did not remain visible after manual disconnect');
    }

    await connectButton.click();
    await disconnectButton.waitFor({ state: 'visible', timeout: 15000 });
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
NODE
}

docker_cac_check_step() {
  docker_cmd check | tee "$LOG_ROOT/docker-check-command.out"
  grep -q '^\[SPD  \]' "$LOG_ROOT/docker-check-command.out"
}

docker_container_check_step() {
  docker exec "$CONTAINER_NAME" cac-check | tee "$LOG_ROOT/container-cac-check.out"
  grep -q '^\[SPD  \]' "$LOG_ROOT/container-cac-check.out"
}

docker_child_wrapper_step() {
  local version_out child_out bridge_user bridge_password expected_all expected_http
  version_out="$(docker exec "$CONTAINER_NAME" docker version --format '{{.Server.Version}}')"
  [[ -n "$version_out" ]]
  bridge_user="$(awk -F= '/^CAC_CHILD_PROXY_BRIDGE_USER=/{print $2}' "$DOCKER_WORKTREE/docker/.env" | tail -n1)"
  bridge_password="$(awk -F= '/^CAC_CHILD_PROXY_BRIDGE_PASSWORD=/{print $2}' "$DOCKER_WORKTREE/docker/.env" | tail -n1)"
  expected_all="socks5h://${bridge_user}:${bridge_password}@host.docker.internal:${BRIDGE_PORT}"
  expected_http="http://${bridge_user}:${bridge_password}@host.docker.internal:${BRIDGE_PORT}"
  child_out="$(
    docker exec "$CONTAINER_NAME" sh -lc \
      "docker run --rm --entrypoint sh -v /workspace:/mnt ${IMAGE_NAME} -lc 'test -d /mnt && printf \"ALL_PROXY=%s\\nHTTP_PROXY=%s\\n\" \"\$ALL_PROXY\" \"\$HTTP_PROXY\" && curl --max-time 10 -fsS https://ifconfig.me >/dev/null'"
  )"
  echo "$child_out" | grep -q "ALL_PROXY=${expected_all}"
  echo "$child_out" | grep -q "HTTP_PROXY=${expected_http}"
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

run_fast_suite() {
  run_step "build-and-js-checks" run_build_checks || true
  run_step "cli-smoke" run_cli_smoke || true
}

prepare_docker_suite() {
  require_tool docker
  require_tool curl
  prepare_docker_worktree
  run_step "proxy-stub" start_proxy_stub || true
  run_step "docker-create" docker_create_step || capture_docker_debug "docker-create"
  run_step "docker-port-autofallback" start_requested_port_blockers || true
  run_step "docker-start" docker_start_step || capture_docker_debug "docker-start"
  run_step "docker-port-autofallback-check" docker_auto_port_step || capture_docker_debug "docker-port-autofallback-check"
  run_step "docker-status" docker_status_step || capture_docker_debug "docker-status"
  run_step "docker-setup-proxy-switch" docker_setup_proxy_switch_step || capture_docker_debug "docker-setup-proxy-switch"
  run_step "docker-shell-switch" docker_shell_switch_step || capture_docker_debug "docker-shell-switch"
}

run_web_suite() {
  run_step "docker-web-ui" docker_web_ui_step || capture_docker_debug "docker-web-ui"
  run_step "docker-web-ui-no-login" docker_web_nologin_step || capture_docker_debug "docker-web-ui-no-login"
  run_step "docker-web-ui-disconnect" docker_web_disconnect_step || capture_docker_debug "docker-web-ui-disconnect"
}

run_security_suite() {
  run_step "docker-check-command" docker_cac_check_step || capture_docker_debug "docker-check-command"
  run_step "container-cac-check" docker_container_check_step || capture_docker_debug "container-cac-check"
  run_step "child-docker-wrapper" docker_child_wrapper_step || capture_docker_debug "child-docker-wrapper"
  run_step "docker-port-forward" docker_port_forward_step || capture_docker_debug "docker-port-forward"
  run_step "docker-fail-closed" docker_fail_closed_step || capture_docker_debug "docker-fail-closed"
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

  case "$VALIDATE_SUITE" in
    fast)
      run_fast_suite
      ;;
    web)
      prepare_docker_suite
      run_web_suite
      run_step "docker-stop" docker_stop_step || capture_docker_debug "docker-stop"
      ;;
    security)
      prepare_docker_suite
      run_security_suite
      run_step "docker-stop" docker_stop_step || capture_docker_debug "docker-stop"
      ;;
    full)
      run_fast_suite
      prepare_docker_suite
      run_web_suite
      run_security_suite
      run_step "docker-stop" docker_stop_step || capture_docker_debug "docker-stop"
      ;;
  esac

  print_summary
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
