# CloudCLI + cac Web Implementation Plan

## Branch

- Branch: `feature/cloudcli-cac-web`
- Base commit at branch creation: `4444dd1`

## Confirmed Decisions

- Service supervision: use `s6` from the start.
- CloudCLI source tracking: vendor upstream git source pinned to a tag/commit.
- Plugin scope for V1: no plugin in the first pass.
- Priority rule: `cac docker` safety, privacy protection, network isolation, and runtime semantics are higher priority than all new Web features.

## Primary Goal

Add browser-based Claude usage to `cac docker` while preserving the `cac` Docker-mode runtime model:

- current active env only
- TUN path and fail-closed expectations stay in the main `cac` container
- persona / runtime env stay under `cac`
- `Xvfb`, `Chromium`, and `Playwright` are available in the same container

## Non-Goals

- no Web-side profile switcher in V1
- no full HolyClaude container transplant
- no new standalone Web service container outside the main `cac` container

## Recommended Repo Layout

Keep the Web integration isolated so future upstream updates are easy to diff.

Suggested structure:

```text
docker/
├── Dockerfile
├── entrypoint.sh
├── s6/
│   ├── cloudcli/
│   │   └── run
│   ├── xvfb/
│   │   └── run
│   └── README.md
├── web/
│   ├── cloudcli-env.sh
│   ├── cloudcli-patches/
│   │   └── README.md
│   └── README.md
└── vendor/
    └── cloudcli/
        ├── UPSTREAM.md
        ├── PATCHES.md
        └── <vendored source or release payload>
```

## What To Modify In `cac`

### 1. `docker/Dockerfile`

Purpose:

- install `CloudCLI`
- install `Chromium`
- install fonts needed by Chromium
- install `Xvfb`
- install `Playwright`

Expected change areas:

- package installation section
- copy vendored Web assets / scripts
- optional plugin installation

### 2. `docker/entrypoint.sh`

Purpose:

- keep existing TUN + persona + runtime init untouched as the primary flow
- after runtime env is ready, prepare CloudCLI compatibility mapping
- hand off to supervised Web/runtime services in the main container

Expected change areas:

- after runtime env exports are finalized
- before final runtime handoff

Likely additions:

- source or generate CloudCLI compatibility env
- create active-env `.claude` mapping to `HOME/.claude`
- ensure `.claude.json` mapping exists
- hand off to `s6`

### 3. `docker/docker-compose.yml`

Purpose:

- expose Web port
- add shared memory sizing for Chromium

Likely changes:

- port mapping for CloudCLI, e.g. `127.0.0.1:3001:3001`
- `shm_size: 2g`

### 4. `docs/zh/guides/docker-mode.mdx` and related docs

Purpose:

- document the Web mode
- explain where the Web UI lives
- explain persistence and known limitations

## What To Vendor / Track From Upstream

There are two upstreams relevant here:

### Upstream A: CloudCLI

- Role: actual Web UI / browser interface
- Track as a functional dependency
- This is the source that will likely require direct patches

Track:

- exact tag or commit
- exact release version
- all local modifications
- last reviewed upstream date

### Upstream B: HolyClaude

- Role: reference implementation for Web hardening and container glue
- Do not treat as code to copy wholesale
- Treat as an implementation reference for:
  - Web runtime fixes
  - startup env choices
  - plugin behavior
  - browser support

Track:

- CloudCLI version they bundle
- any extra patches they apply to CloudCLI
- any useful startup/runtime fixes around `WORKSPACES_ROOT`, SQLite, WebSocket plugins, `Xvfb`, and browser support

## Patch Strategy For CloudCLI

### Principle

Do not scatter ad hoc edits.

Instead:

1. add one compatibility helper layer
2. replace hardcoded `.claude` / `.claude.json` usages with helper calls
3. document every touched file in `PATCHES.md`

### Patch Categories

#### Category A: path compatibility

Goal:

- make CloudCLI operate on the current active `cac` env

Examples:

- config root
- projects root
- sessions root
- `.claude.json`
- commands root
- external-projects root

#### Category B: runtime binding

Goal:

- ensure CloudCLI-started Claude usage still runs under `cac` runtime expectations

Examples:

- spawned CLI paths
- shell / PTY launch path
- environment passed to Claude SDK or CLI flows

#### Category C: Web runtime hardening

Goal:

- port HolyClaude-style proven Web fixes without porting the whole container

Examples:

- `WORKSPACES_ROOT=/workspace`
- CloudCLI DB location
- `HOME` handling
- `DISPLAY=:99`
- WebSocket plugin patch if still needed

## Fast Upgrade Workflow

When CloudCLI updates:

1. fetch new upstream source/tag
2. compare against `vendor/cloudcli/UPSTREAM.md`
3. run targeted diffs over:
   - `server/projects.js`
   - `server/index.js`
   - `server/routes/cli-auth.js`
   - `server/routes/mcp.js`
   - `server/utils/mcp-detector.js`
   - `server/claude-sdk.js`
   - `server/routes/agent.js`
   - `server/routes/commands.js`
   - any local helper module added by `cac`
4. replay or adapt patches listed in `vendor/cloudcli/PATCHES.md`
5. validate inside `cac docker`

When HolyClaude updates:

1. inspect their bundled CloudCLI version
2. inspect any new Dockerfile patch to CloudCLI
3. inspect service startup changes around:
   - `WORKSPACES_ROOT`
   - `HOME`
   - `DISPLAY`
   - plugin support
   - browser/runtime fixes
4. decide whether each change belongs in:
   - CloudCLI patch layer
   - `cac docker` runtime glue
   - docs only

## Files To Create For Update Tracking

### `docker/vendor/cloudcli/UPSTREAM.md`

Record:

- upstream repo URL
- upstream tag/commit
- release date
- source acquisition method

### `docker/vendor/cloudcli/PATCHES.md`

Record per patch:

- patch id
- affected files
- reason
- whether inspired by HolyClaude or `cac`
- how to verify

### `docker/web/README.md`

Record:

- service startup order
- required env vars
- known runtime assumptions

## Testing Rule

The original `cac docker` protection model is the release gate.

Web support is acceptable only if the original privacy and network-management guarantees still pass strictly.

## Required Test Gates

### Gate 1: original `cac docker` protections

Strict blockers:

- TUN comes up correctly
- DNS path remains protected
- TCP / HTTP checks still behave correctly
- fail-closed behavior still holds when the proxy is interrupted
- exit-IP checks still pass
- SSH path still works if enabled
- identity/persona masking still passes `cac docker check`
- workspace mount and Docker wrapper behavior remain correct

### Gate 2: startup/runtime compatibility

- current active env is still the effective env used by Claude
- no silent fallback to default host-style `~/.claude`
- CloudCLI startup does not bypass `cac` runtime assumptions
- Web startup order does not race ahead of TUN / persona / env preparation

### Gate 3: new Web layer validation

- CloudCLI opens successfully on the published port
- default workspace resolves to `/workspace`
- current active env sessions/config are visible in the Web UI
- Chromium starts correctly
- `Xvfb` provides a working display
- Playwright can launch against the installed browser
- `s6` recovery/restart behavior is sane

## Validation Order

Always validate in this order:

1. existing `cac docker` security/privacy/network checks
2. startup/runtime compatibility checks
3. Web UI feature checks

If step 1 fails, stop. Do not continue feature validation until protection regressions are fixed.

## Development Phases

### Phase 1: scaffold

- create vendor and Web overlay layout
- define upstream tracking files
- vendor CloudCLI upstream git source at an exact tag/commit
- add `s6` service layout

### Phase 2: runtime integration

- install Web runtime dependencies
- add `s6`-managed CloudCLI/Xvfb startup
- expose Web port
- add active-env filesystem mapping

### Phase 3: CloudCLI compatibility patch

- add path helper
- patch direct `.claude` assumptions
- patch runtime entry points that need explicit `cac` binding

### Phase 4: hardening

- browser startup validation
- Web healthcheck
- plugin transport validation
- SQLite persistence validation
- strict regression validation for original `cac docker` privacy/network behavior

### Phase 5: docs and upgrade process

- document feature usage
- document known limits
- document upstream update workflow

## Confirmed User Choices

1. CloudCLI source of truth:
   - confirmed: vendor upstream git source pinned to a tag/commit

2. Plugin scope for V1:
   - confirmed: no plugin in the first pass

3. Service supervision for V1:
   - confirmed: use `s6` from the beginning
