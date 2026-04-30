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
  - `docker/entrypoint.sh`
  - `docker/web/cloudcli-env.sh`
- Reason: keep CloudCLI compatible with the current active `cac` env by mapping
  the active profile's Claude state into the `HOME/.claude*` locations that the
  pinned CloudCLI version still expects
- Verification:
  - project/session/config discovery still works through the active env mapping
  - Web mode sees the active profile's `.claude` and `.claude.json` state
- Upstream status: `cac`-specific runtime compatibility layer

### `CAC-AUTH-001`

- Status: implemented
- Files:
  - `docker/web/cloudcli-bootstrap-user.sh`
  - `docker/s6/cloudcli/run`
  - `docker/vendor/cloudcli/upstream/server/middleware/auth.js`
  - `docker/vendor/cloudcli/upstream/src/components/auth/view/ProtectedRoute.tsx`
- Reason: keep Docker Web mode in no-login platform mode so browser access goes
  straight into the app instead of stopping on CloudCLI auth pages
- Verification:
  - `/api/auth/user` responds without a manual login
  - the Web UI does not show login/signup forms in Docker platform mode
- Upstream status: `cac`-specific unless CloudCLI gains a first-class single-user Docker mode

### `CAC-SHELL-001`

- Status: implemented
- Files:
  - `docker/vendor/cloudcli/upstream/src/components/shell/hooks/useShellConnection.ts`
  - `docker/vendor/cloudcli/upstream/src/components/shell/hooks/useShellRuntime.ts`
  - `docker/vendor/cloudcli/upstream/src/components/shell/types/types.ts`
  - `docker/vendor/cloudcli/upstream/src/components/shell/view/Shell.tsx`
- Reason: preserve a true manual Disconnect behavior; clicking `Disconnect`
  must keep the shell disconnected until the user explicitly reconnects
- Verification:
  - Web validation clicks `Disconnect`
  - `Connect` remains visible
  - the shell does not auto-reconnect until the user clicks `Connect`
- Upstream status: good upstream candidate if CloudCLI wants clearer manual-vs-auto reconnect semantics

### `CAC-UPDATE-001`

- Status: implemented
- Files:
  - `docker/s6/cloudcli/run`
  - `docker/vendor/cloudcli/upstream/server/cli.js`
- Reason: disable CloudCLI update checks in Docker runtime so startup does not
  make unnecessary external calls
- Verification:
  - startup works without update-check noise
  - Docker Web mode does not depend on outbound update checks
- Upstream status: `cac`-specific runtime policy

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
