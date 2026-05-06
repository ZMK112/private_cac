#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=0
SKIP_DOCKER=0

usage() {
  cat <<'EOF'
Usage: bash scripts/post-release-cleanup.sh [options]

Safe post-release housekeeping for local developer machines.

It removes:
- /tmp validation and manual-test scratch directories
- repo-local __pycache__ directories
- unused Docker images, networks, stopped containers, and build cache

It does not remove:
- running containers
- Docker volumes
- cac Docker persisted Claude state under docker/data or CAC_DATA
- dist/ release assets

Options:
  --dry-run      Print planned actions without deleting anything
  --skip-docker  Skip Docker cleanup
  -h, --help     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-docker) SKIP_DOCKER=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

log() {
  printf '[cleanup] %s\n' "$*"
}

docker_cmd() {
  if [[ -x /Applications/OrbStack.app/Contents/MacOS/xbin/docker ]]; then
    /Applications/OrbStack.app/Contents/MacOS/xbin/docker "$@"
  else
    docker "$@"
  fi
}

docker_ready() {
  docker_cmd version >/dev/null 2>&1
}

clean_tmp_dirs() {
  local pattern
  local patterns=(
    'cac-validate-*'
    'cacmanual*'
    'cac-web-*'
    'proxy-stub-*'
  )

  log "Cleaning temporary validation directories under /tmp"
  for pattern in "${patterns[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then
      find /tmp -maxdepth 1 -name "$pattern" -print | sort
    else
      find /tmp -maxdepth 1 -name "$pattern" -exec rm -rf {} +
    fi
  done
}

clean_pycache() {
  log "Cleaning repo-local __pycache__ directories"
  if [[ "$DRY_RUN" == "1" ]]; then
    find "$ROOT_DIR" -type d -name __pycache__ -prune -print | sort
    return 0
  fi
  find "$ROOT_DIR" -type d -name __pycache__ -prune -exec rm -rf {} +
}

clean_docker() {
  if [[ "$SKIP_DOCKER" == "1" ]]; then
    log "Skipping Docker cleanup by request"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Docker cleanup plan"
    printf '+ docker system prune -af\n'
    printf '+ docker builder prune -af\n'
    return 0
  fi

  if ! docker_ready; then
    log "Docker runtime not ready; skipping Docker cleanup"
    return 0
  fi

  log "Docker disk usage before cleanup"
  docker_cmd system df || true

  log "Pruning unused Docker images, networks, and stopped containers"
  docker_cmd system prune -af

  log "Pruning unused Docker build cache"
  docker_cmd builder prune -af

  log "Docker disk usage after cleanup"
  docker_cmd system df || true
}

log "Starting post-release cleanup"
clean_tmp_dirs
clean_pycache
clean_docker
log "Post-release cleanup complete"
