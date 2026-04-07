#!/usr/bin/env bash
set -euo pipefail

CAC_FAKE_HOME="${CAC_FAKE_HOME:-/home/cherny}"
CAC_DIR="${CAC_DIR:-${CAC_FAKE_HOME}/.cac}"
CAC_RUNTIME_USER="${CAC_RUNTIME_USER:-${CAC_FAKE_USER:-cherny}}"
CAC_WEB_PORT="${CAC_WEB_PORT:-3001}"
WORKSPACES_ROOT="${WORKSPACES_ROOT:-/workspace}"
DISPLAY="${DISPLAY:-:99}"
PATH_WITH_CAC="${CAC_DIR}/bin:${CAC_DIR}/shim-bin:${PATH}"

current_env=""
if [[ -f "${CAC_DIR}/current" ]]; then
  current_env="$(tr -d '[:space:]' < "${CAC_DIR}/current")"
fi

active_env_dir=""
if [[ -n "$current_env" ]]; then
  active_env_dir="${CAC_DIR}/envs/${current_env}"
fi

active_claude_dir="${CAC_FAKE_HOME}/.claude"
if [[ -n "$active_env_dir" && -d "${active_env_dir}/.claude" ]]; then
  active_claude_dir="${active_env_dir}/.claude"
fi

active_claude_json="${CAC_FAKE_HOME}/.claude.json"
active_projects_dir="${active_claude_dir}/projects"
active_sessions_dir="${active_claude_dir}/sessions"
active_commands_dir="${active_claude_dir}/commands"
active_external_projects_dir="${active_claude_dir}/external-projects"

mkdir -p "${CAC_FAKE_HOME}/.cloudcli"

cat > /etc/cac-cloudcli.env <<EOF
export HOME="${CAC_FAKE_HOME}"
export USER="${CAC_RUNTIME_USER}"
export LOGNAME="${CAC_RUNTIME_USER}"
export WORKSPACES_ROOT="${WORKSPACES_ROOT}"
export DISPLAY="${DISPLAY}"
export DATABASE_PATH="${CAC_FAKE_HOME}/.cloudcli/auth.db"
export PATH="${PATH_WITH_CAC}"
export CLAUDE_CLI_PATH="${CAC_DIR}/bin/claude"
export CAC_ACTIVE_CLAUDE_DIR="${active_claude_dir}"
export CAC_ACTIVE_CLAUDE_JSON="${active_claude_json}"
export CAC_ACTIVE_PROJECTS_DIR="${active_projects_dir}"
export CAC_ACTIVE_SESSIONS_DIR="${active_sessions_dir}"
export CAC_ACTIVE_COMMANDS_DIR="${active_commands_dir}"
export CAC_ACTIVE_EXTERNAL_PROJECTS_DIR="${active_external_projects_dir}"
export CAC_WEB_PORT="${CAC_WEB_PORT}"
export CAC_RUNTIME_USER="${CAC_RUNTIME_USER}"
EOF
