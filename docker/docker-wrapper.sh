#!/usr/bin/env bash
set -euo pipefail

REAL_DOCKER_BIN="${CAC_REAL_DOCKER_BIN:-/usr/local/bin/docker-real}"
SHARED_ROOT="${CAC_SHARED_WORKSPACE:-/workspace}"
HOST_ROOT="${CAC_SHARED_WORKSPACE_HOST:-}"
PARENT_CONTAINER="${CAC_PARENT_CONTAINER_NAME:-boris-main}"
DEFAULT_NETWORK="${CAC_CHILD_CONTAINER_NETWORK_MODE:-bridge}"
CHILD_PROXY_URL="${CAC_CHILD_CONTAINER_PROXY_URL:-}"
CHILD_HTTP_PROXY_URL="${CAC_CHILD_CONTAINER_HTTP_PROXY_URL:-${CHILD_PROXY_URL}}"
CHILD_ALL_PROXY_URL="${CAC_CHILD_CONTAINER_ALL_PROXY_URL:-${CHILD_PROXY_URL}}"
CHILD_NO_PROXY="${CAC_CHILD_CONTAINER_NO_PROXY:-localhost,127.0.0.1,::1}"
ADD_HOST_GATEWAY="${CAC_CHILD_CONTAINER_ADD_HOST_GATEWAY:-1}"

if [[ ! -x "$REAL_DOCKER_BIN" ]]; then
  echo "docker wrapper: real docker binary not found at ${REAL_DOCKER_BIN}" >&2
  exit 127
fi

subcmd=""
for arg in "$@"; do
  if [[ "$arg" != -* ]]; then
    subcmd="$arg"
    break
  fi
done

has_network_flag=0
has_add_host_flag=0
for arg in "$@"; do
  case "$arg" in
    --network|--net|--network=*|--net=*)
      has_network_flag=1
      ;;
    --add-host|--add-host=*)
      has_add_host_flag=1
      ;;
  esac
done

warn_outside_workspace=0

is_bind_source() {
  local src="$1"
  [[ "$src" == /* || "$src" == . || "$src" == .. || "$src" == ./* || "$src" == ../* || "$src" == ~* || "$src" == */* ]]
}

resolve_path() {
  local path="$1"
  python3 - "$PWD" "$path" <<'PY'
import os
import sys

cwd, raw = sys.argv[1], sys.argv[2]
print(os.path.abspath(os.path.expanduser(raw) if raw.startswith("~") else os.path.join(cwd, raw)))
PY
}

map_host_path() {
  local src="$1" resolved=""

  if [[ -z "$HOST_ROOT" ]]; then
    printf '%s' "$src"
    return 0
  fi

  if [[ "$src" == "$SHARED_ROOT" || "$src" == "$SHARED_ROOT/"* ]]; then
    printf '%s%s' "$HOST_ROOT" "${src#$SHARED_ROOT}"
    return 0
  fi

  if is_bind_source "$src"; then
    resolved="$(resolve_path "$src")"
    if [[ "$resolved" == "$SHARED_ROOT" || "$resolved" == "$SHARED_ROOT/"* ]]; then
      printf '%s%s' "$HOST_ROOT" "${resolved#$SHARED_ROOT}"
      return 0
    fi
  fi

  if [[ "$src" == /* || "$src" == . || "$src" == .. || "$src" == ./* || "$src" == ../* || "$src" == ~* ]]; then
    warn_outside_workspace=1
  fi
  printf '%s' "$src"
}

rewrite_volume_spec() {
  local spec="$1" src="" rest="" mapped=""

  [[ "$spec" == *:* ]] || { printf '%s' "$spec"; return 0; }

  src="${spec%%:*}"
  rest="${spec#*:}"
  if ! is_bind_source "$src"; then
    printf '%s' "$spec"
    return 0
  fi

  mapped="$(map_host_path "$src")"
  printf '%s:%s' "$mapped" "$rest"
}

rewrite_mount_spec() {
  local spec="$1" IFS=, parts=() out=() part="" key="" value=""
  local is_bind=0

  read -r -a parts <<< "$spec"
  for part in "${parts[@]}"; do
    key="${part%%=*}"
    value="${part#*=}"
    if [[ "$key" == "type" && "$value" == "bind" ]]; then
      is_bind=1
    fi
  done

  if [[ "$is_bind" -eq 0 ]]; then
    printf '%s' "$spec"
    return 0
  fi

  for part in "${parts[@]}"; do
    key="${part%%=*}"
    value="${part#*=}"
    case "$key" in
      src|source)
        out+=("${key}=$(map_host_path "$value")")
        ;;
      *)
        out+=("$part")
        ;;
    esac
  done

  local joined=""
  for part in "${out[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+=","
    fi
    joined+="$part"
  done
  printf '%s' "$joined"
}

args=()
inject_run_defaults=0
if [[ "$subcmd" == "run" || "$subcmd" == "create" ]]; then
  inject_run_defaults=1
fi

injected_after_subcmd=0
expect_value=""
for arg in "$@"; do
  if [[ -n "$expect_value" ]]; then
    case "$expect_value" in
      volume)
        args+=("$(rewrite_volume_spec "$arg")")
        ;;
      mount)
        args+=("$(rewrite_mount_spec "$arg")")
        ;;
      *)
        args+=("$arg")
        ;;
    esac
    expect_value=""
    continue
  fi

  args+=("$arg")

  if [[ "$arg" == "$subcmd" && "$injected_after_subcmd" -eq 0 ]]; then
    if [[ "$inject_run_defaults" -eq 1 && "$has_network_flag" -eq 0 && -n "$DEFAULT_NETWORK" ]]; then
      args+=("--network=${DEFAULT_NETWORK}")
    fi
    if [[ "$inject_run_defaults" -eq 1 ]]; then
      if [[ "$ADD_HOST_GATEWAY" == "1" && "$has_add_host_flag" -eq 0 ]]; then
        args+=("--add-host=host.docker.internal:host-gateway")
      fi
      args+=("--label=com.studio.managed=true" "--label=com.studio.parent=${PARENT_CONTAINER}")
      if [[ -n "$CHILD_ALL_PROXY_URL" || -n "$CHILD_HTTP_PROXY_URL" ]]; then
        args+=(
          "--env=ALL_PROXY=${CHILD_ALL_PROXY_URL}"
          "--env=all_proxy=${CHILD_ALL_PROXY_URL}"
          "--env=HTTP_PROXY=${CHILD_HTTP_PROXY_URL}"
          "--env=http_proxy=${CHILD_HTTP_PROXY_URL}"
          "--env=HTTPS_PROXY=${CHILD_HTTP_PROXY_URL}"
          "--env=https_proxy=${CHILD_HTTP_PROXY_URL}"
          "--env=NO_PROXY=${CHILD_NO_PROXY}"
          "--env=no_proxy=${CHILD_NO_PROXY}"
        )
      fi
    fi
    injected_after_subcmd=1
    continue
  fi

  case "$arg" in
    -v|--volume)
      expect_value="volume"
      ;;
    --mount)
      expect_value="mount"
      ;;
    --volume=*|-v=*)
      args[-1]="${arg%%=*}=$(rewrite_volume_spec "${arg#*=}")"
      ;;
    --mount=*)
      args[-1]="--mount=$(rewrite_mount_spec "${arg#*=}")"
      ;;
  esac
done

if [[ "$warn_outside_workspace" -eq 1 ]]; then
  cat >&2 <<EOF
docker wrapper: bind mounts outside ${SHARED_ROOT} are not remapped.
Put projects under ${SHARED_ROOT} if child containers need host-visible bind mounts.
EOF
fi

exec "$REAL_DOCKER_BIN" "${args[@]}"
