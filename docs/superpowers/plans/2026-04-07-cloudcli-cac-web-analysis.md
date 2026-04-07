# CloudCLI + cac Web Integration Analysis

## Goal

Evaluate whether `CloudCLI` can be sourced, modified, and maintained as a `cac`-native Web layer so that:

- browser access uses the current active `cac` env
- `cac docker` remains the protected runtime base
- future `CloudCLI` and HolyClaude Web-related changes can be tracked and re-applied with controlled diffs

## Short Answer

Yes, this is feasible.

The recommended path is:

1. vendor `CloudCLI` source at an exact upstream version
2. add a small `cac` compatibility layer for Claude config/session paths and startup env
3. keep a patch map so future upgrades only need a targeted re-diff

This is more work than "just install CloudCLI", but much less work than writing a new Web UI.

## Source Acquisition Options

### Option A: Git upstream source

- Source: `https://github.com/siteboon/claudecodeui`
- Pros:
  - easiest to diff against future upstream commits and tags
  - easier to maintain a local patch series
- Cons:
  - upstream HEAD may move in ways unrelated to the version already validated elsewhere

### Option B: npm tarball

- Source package: `@siteboon/claude-code-ui`
- Pros:
  - exact, reproducible release payload
  - matches what HolyClaude vendors
- Cons:
  - harder to diff cleanly against future source changes than a git remote

### Recommendation

- For long-term `cac` maintenance, prefer a vendored upstream git checkout pinned to a tag/commit.
- Keep a patch log and an upgrade checklist.
- If exact reproducibility matters more than patch ergonomics, keep the npm tarball as a fallback reference.

## Why a Fork / Patch Layer Makes Sense

Installing `CloudCLI` unmodified is not enough for `cac`.

Reasons:

- `cac` isolates Claude via `CLAUDE_CONFIG_DIR=~/.cac/envs/<name>/.claude`
- `CloudCLI` hardcodes many reads and writes under `os.homedir()/.claude` and `os.homedir()/.claude.json`
- `CloudCLI` also spawns `claude` directly in some routes and uses Claude SDK code in others
- `cac` protection semantics depend on startup env, wrapper behavior, active env selection, and injected runtime variables

So the real task is not "run CloudCLI"; it is "make CloudCLI understand the active `cac` env and run inside `cac` runtime semantics".

## What To Patch In CloudCLI

### Core idea

Introduce a small path resolution module, then replace direct `.claude` / `.claude.json` assumptions with helper calls.

Suggested helper module responsibilities:

- resolve current Claude config root
- resolve current Claude projects root
- resolve current Claude sessions root
- resolve current Claude user settings file
- resolve current `.claude.json`
- resolve external-projects and commands directories

Suggested env inputs:

- `CAC_ACTIVE_CLAUDE_DIR`
- `CAC_ACTIVE_CLAUDE_JSON`
- `CAC_ACTIVE_PROJECTS_DIR`
- `CAC_ACTIVE_SESSIONS_DIR`
- `CAC_ACTIVE_COMMANDS_DIR`
- `CAC_ACTIVE_EXTERNAL_PROJECTS_DIR`

Fallback behavior:

- if `cac` vars are missing, use CloudCLI upstream defaults

This keeps the fork maintainable and makes future rebases easier.

## CloudCLI Hotspots To Modify

These are the main places in the inspected `siteboon-claude-code-ui-1.26.3` payload that are directly relevant to `cac` integration.

### Path hardcodes that must be abstracted

- `server/projects.js`
  - heavy use of `~/.claude/projects`
  - also uses `~/.claude/project-config.json`
- `server/index.js`
  - watches `~/.claude/projects`
  - resolves Claude session project JSONL paths directly
- `server/routes/cli-auth.js`
  - reads `~/.claude/settings.json`
  - reads `~/.claude/.credentials.json`
- `server/routes/mcp.js`
  - reads `~/.claude.json`
  - reads `~/.claude/settings.json`
  - spawns `claude` directly
- `server/utils/mcp-detector.js`
  - reads `~/.claude.json`
  - reads `~/.claude/settings.json`
- `server/claude-sdk.js`
  - reads `~/.claude.json`
- `server/cli.js`
  - status output checks `~/.claude/projects`
- `server/routes/agent.js`
  - uses `~/.claude/sessions`
  - uses `~/.claude/external-projects`
- `server/routes/commands.js`
  - uses `~/.claude/commands`

### CLI / runtime coupling that must be reviewed

- `server/routes/mcp.js`
  - direct `spawn('claude', ...)`
- `server/index.js`
  - PTY and shell startup paths
- `server/claude-sdk.js`
  - Claude SDK query flow

These need validation so browser-triggered Claude sessions still inherit `cac` runtime semantics.

## Best Integration Strategy

### Strategy 1: filesystem compatibility first

Make the active env look like upstream expects:

- current active env `.claude` exposed as `HOME/.claude`
- active env-compatible `.claude.json` exposed as `HOME/.claude.json`

Pros:

- smaller CloudCLI patch set
- faster first milestone

Cons:

- still leaves many `cac` semantics implicit
- more fragile if startup env is wrong

### Strategy 2: patch CloudCLI to be `cac`-aware

Add a compatibility layer and use env-driven path resolution.

Pros:

- much cleaner long term
- easier to reason about
- future diffs stay localized

Cons:

- more initial patch work

### Recommended approach

- Use Strategy 1 for initial compatibility and bootstrapping
- Immediately layer Strategy 2 on top so path ownership becomes explicit

This avoids a giant first patch while still moving toward a maintainable fork.

## HolyClaude: What It Actually Adds For Web Use

HolyClaude does not reinvent Web Claude. It packages and hardens CloudCLI.

### Confirmed Web-related optimizations in HolyClaude

1. Vendored CloudCLI release payload

- avoids waiting on npm/upstream timing
- lets the image ship with a known-good UI build

2. WebSocket plugin proxy patch

- HolyClaude patches CloudCLI's plugin proxy to preserve WebSocket frame binary/text type in both directions
- purpose: fix Web Terminal / plugin transport behavior

3. Explicit `WORKSPACES_ROOT=/workspace`

- ensures CloudCLI opens the correct default workspace
- important because their supervisor launches with a clean env

4. Explicit `HOME=/home/claude`

- keeps CloudCLI reading the right config roots

5. `NODE_OPTIONS=--no-deprecation`

- suppresses noisy runtime warnings in service logs

6. Keep CloudCLI DB on container-local storage

- avoids SQLite lock problems on SMB/CIFS/NAS mounts

7. Bake plugins into the image

- `project-stats`
- `web-terminal`

8. Run `Xvfb`

- provides a virtual display at `:99`

9. Install `Chromium` and `Playwright`

- enables browser automation, screenshots, and related tasks out of the box

10. Healthcheck on Web service

- simple availability check for the Web UI

## HolyClaude Web Optimizations Worth Re-implementing

These should be considered for `cac docker`:

- exact `WORKSPACES_ROOT=/workspace`
- `HOME` explicitly set for CloudCLI service
- CloudCLI DB on persistent local home storage, not `/workspace`
- WebSocket frame-type patch if the upstream version still needs it
- optional baked-in Web Terminal plugin
- `Xvfb + DISPLAY=:99`
- `Chromium` + fonts + `Playwright`
- Web healthcheck

## What Not To Copy Blindly

- HolyClaude's entire container architecture
- HolyClaude's assumptions around a single default `~/.claude` world
- HolyClaude's full process supervision choice as an initial requirement

`cac docker` already has a strong runtime model. The Web layer should adapt to it, not replace it.

## Main Risks / Problems

### 1. CloudCLI mixes Claude CLI and Claude SDK paths

This means path fixes alone are not enough.

Need to verify:

- spawned CLI flows use `cac` runtime env
- SDK flows do not silently bypass important `cac` protection semantics

### 2. Too much direct `.claude` usage upstream

Without a helper abstraction, future upgrades will be painful because hardcoded path references are spread across multiple files.

### 3. Startup ordering matters

CloudCLI must start only after:

- TUN is up
- runtime env file is ready
- active env is known
- compatibility mapping is in place

### 4. License / distribution implications

If distributed inside `cac docker`, keep track of the fact that CloudCLI is a separate third-party component with its own license obligations.

### 5. Browser support is not the same as browser automation

CloudCLI itself does not require `Xvfb/Chromium/Playwright`.

Those are separate runtime enhancements:

- useful
- likely desired
- but not required for basic browser access to Claude

## Recommended Implementation Order

### Phase 1: compatibility bootstrap

- vendor exact CloudCLI source
- add compatibility path helper
- map active env paths into CloudCLI
- run CloudCLI inside `cac docker`
- expose Web port

### Phase 2: runtime hardening

- verify CLI-spawned Claude flows use `cac` semantics
- verify SDK flows under `cac` runtime env
- add healthcheck
- keep DB on persistent local home storage

### Phase 3: Web UX parity

- add `Xvfb`
- add `Chromium`
- add `Playwright`
- optionally add Web Terminal plugin
- apply WebSocket patch if still needed

## Upgrade Workflow Recommendation

For each future CloudCLI upgrade:

1. pull or vendor the new upstream tag/release
2. run a search for:
   - `os.homedir()`
   - `.claude`
   - `.claude.json`
   - `spawn('claude'`
   - `query(`
3. diff against the local compatibility helper and patched call sites
4. re-check HolyClaude for:
   - CloudCLI version bump
   - new Web patches
   - plugin/runtime fixes
5. run integration validation inside `cac docker`

## Practical Recommendation

This approach is worth doing.

The maintainable version is:

- fork or vendor CloudCLI source
- centralize `cac` path compatibility in one helper module
- keep a small documented patch surface
- borrow only HolyClaude's proven Web/runtime hardening pieces

That gives the best balance of:

- `cac` compatibility
- future upgradeability
- not being hostage to HolyClaude's full container implementation
