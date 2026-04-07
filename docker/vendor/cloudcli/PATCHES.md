# CloudCLI Local Patch Log

This file tracks all local modifications applied on top of the vendored
CloudCLI upstream source.

Patch format:

- Patch ID
- Status
- Files touched
- Reason
- Verification method
- Upstream status

## Current Patch Set

### `CAC-BOOT-001`

- Status: implemented
- Files:
  - `docker/entrypoint.sh`
  - `docker/s6/cloudcli/run`
  - `docker/s6/xvfb/run`
  - `docker/web/cloudcli-env.sh`
  - `docker/docker-compose.yml`
  - `docker/.env.example`
- Reason: add Web runtime bootstrapping on top of `cac docker` while preserving
  the original protected container model
- Verification:
  - image build succeeds
  - `cloudcli`, `chromium`, `Xvfb`, and `playwright` are callable in the built image
  - manual protected Docker-mode stack starts successfully
  - `cac-check` passes in the protected container
- Upstream status: `cac`-specific, not for upstream

### `CAC-S6-001`

- Status: implemented
- Files:
  - `docker/Dockerfile`
  - `docker/s6/cloudcli/type`
  - `docker/s6/cloudcli/run`
  - `docker/s6/xvfb/type`
  - `docker/s6/xvfb/run`
- Reason: introduce `s6-overlay` from the start and supervise Web services under
  the runtime user model
- Verification:
  - main container starts under `cac docker start`
  - `s6` launches `cloudcli` and `xvfb`
  - `cac-check` reports `PID1` as non-root after switching `/init` to runtime user
- Upstream status: `cac`-specific, not for upstream

### `CAC-PATH-001`

- Status: implemented
- Files:
  - `docker/vendor/cloudcli/upstream/server/utils/cac-paths.js`
  - `docker/vendor/cloudcli/upstream/server/cli.js`
  - `docker/vendor/cloudcli/upstream/server/index.js`
  - `docker/vendor/cloudcli/upstream/server/claude-sdk.js`
  - `docker/vendor/cloudcli/upstream/server/projects.js`
  - `docker/vendor/cloudcli/upstream/server/routes/agent.js`
  - `docker/vendor/cloudcli/upstream/server/routes/cli-auth.js`
  - `docker/vendor/cloudcli/upstream/server/routes/commands.js`
  - `docker/vendor/cloudcli/upstream/server/routes/mcp.js`
  - `docker/vendor/cloudcli/upstream/server/utils/mcp-detector.js`
- Reason: replace hardcoded `os.homedir()/.claude*` assumptions with a small
  compatibility helper layer so future upgrades are easier to rebase
- Verification:
  - project/session/config discovery still works
  - no fallback to host-style default config roots
  - explicit Claude CLI entry points now use helper-backed command resolution in
    both MCP routes and the interactive shell path
- Upstream status: `cac`-specific unless generalized cleanly

### `HC-WS-001`

- Status: planned review
- Files: CloudCLI WebSocket plugin proxy path if still needed on the pinned
  version
- Reason: HolyClaude carries a patch to preserve WebSocket frame type in plugin
  relay paths; this may be required later for Web Terminal compatibility
- Verification:
  - plugin transport keeps working with binary/text WebSocket frames
- Upstream status: re-check when plugin support is introduced

### `CAC-VAL-001`

- Status: implemented
- Files:
  - `scripts/validate.sh`
  - `TESTING.md`
- Reason:
  - keep the automated Docker-mode validation aligned with the new Web-enabled
    runtime
  - avoid validation-only port collisions by assigning unique SSH/Web ports
  - add an automated Web UI reachability gate
- Verification:
  - full validation completes with `13` pass / `0` fail / `0` warn
  - `docker-web-ui` step passes
  - original `docker-fail-closed` and `container-cac-check` steps still pass
- Upstream status: `cac`-specific test harness change
