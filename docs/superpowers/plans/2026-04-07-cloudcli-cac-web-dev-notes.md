# CloudCLI + cac Web Development Notes

## Purpose

This note records the practical implementation details, debugging tricks, and
mistakes discovered while adding browser-based Claude usage to `cac docker`.

It is intended to make future development and upstream update work faster and
less error-prone.

## Scope Of This Work

Implemented in branch:

- `feature/cloudcli-cac-web`

Main outcome:

- `cac docker` now has a supervised Web layer (`CloudCLI + Xvfb + Chromium + Playwright`)
- the original `cac docker` protection model still passes validation
- automated validation now also checks Web UI reachability

## High-Level Implementation Shape

The final shape that worked:

1. keep `cac docker` as the runtime/security base
2. vendor `CloudCLI` source at a pinned upstream version
3. add a small `cac` compatibility layer for Claude paths
4. run Web services inside the same protected main container
5. supervise Web services with `s6`
6. validate original privacy/network guarantees before trusting Web functionality

This was the right tradeoff.

Trying to copy the whole HolyClaude container design would have created more
 drift and less control.

## Files / Layers That Matter Most

### `docker/Dockerfile`

This became the convergence point for:

- `s6-overlay`
- `CloudCLI`
- `Chromium`
- `Xvfb`
- `Playwright`

Important lesson:

- installing `CloudCLI` from local source with `npm install -g .` is fragile in
  Docker because npm can create a global symlink back into the build context
  directory
- once that source directory is removed, the `cloudcli` binary becomes broken

What worked:

- build the source
- pack it into a tarball
- install the tarball globally

### `docker/entrypoint.sh`

This is still the core runtime bootstrap.

Important lesson:

- do not move security/runtime initialization into `s6`
- TUN, persona, env generation, and active-env mapping must happen first
- only after that should `/init` be handed off

### `docker/s6/`

This layer only exists to supervise long-running services.

Important lesson:

- `s6` should not replace `cac` runtime logic
- it should only run services after `cac` runtime preconditions are satisfied

### `docker/web/cloudcli-env.sh`

This became the glue between `cac` and `CloudCLI`.

Important lesson:

- if you want deterministic behavior, write the CloudCLI compatibility env file
  explicitly
- do not rely on PATH or HOME being implicitly "good enough"

### `docker/vendor/cloudcli/upstream/server/utils/cac-paths.js`

This helper was the key maintainability move.

Important lesson:

- replacing hardcoded `.claude` usage file-by-file without a helper creates
  upgrade pain
- centralizing path resolution drastically reduces future rebase work

## Most Important Technical Lessons

### 1. Path compatibility is not optional

`cac` isolates Claude with:

- `CLAUDE_CONFIG_DIR=~/.cac/envs/<name>/.claude`

CloudCLI upstream assumes:

- `HOME/.claude`
- `HOME/.claude.json`

If you do not bridge those worlds explicitly, the Web UI will drift away from
the real active `cac` env.

### 2. PATH-based luck is not enough

At first glance, it looks like putting `~/.cac/bin` first in `PATH` is enough.

That is not robust.

Why:

- CloudCLI has multiple execution paths
- some paths use PTY shell commands
- some routes spawn CLI commands directly
- some logic uses the Claude SDK

What worked better:

- export `CLAUDE_CLI_PATH`
- add helper-backed command resolution
- make important call sites use the helper explicitly

### 3. Web service startup order matters

A correct startup order is:

1. TUN/network path ready
2. runtime env file ready
3. active profile ready
4. filesystem compatibility mapping ready
5. `s6` starts Web services

Starting CloudCLI before the active-env mapping exists is a real bug, not just
a cosmetic issue.

### 4. `s6` path assumptions can bite

Using `s6-setuidgid` without its absolute path caused repeated service failure
inside the container.

What worked:

- use `/command/s6-setuidgid`

### 5. PID1 matters for `cac-check`

Initially, Web integration passed most checks but failed:

- `PID1` still running as root

That was important because it meant the original `cac docker` identity/runtime
expectations were no longer fully preserved.

What worked:

- keep root long enough to do pre-`s6` setup
- hand off with `exec_as_runtime_user /init "$@"`
- let `cloudcli` run directly under the already dropped runtime user

That restored:

- `PID1` non-root
- `cac-check` green path

### 6. Docker validation can fail because of the harness, not the product

The repo validation initially failed for reasons that were not product
regressions:

- mutable validation image tag (`latest`) violated pinned-image rules
- fixed SSH port `2222` collided with already-running local stacks
- Web port was not part of validation at all
- a custom fix introduced an infinite loop because the same port allocator was
  reused for all ports

Important lesson:

- do not trust the first failing automated test without checking whether the
  harness itself still matches the product rules

## Concrete Mistakes And Fixes

### Mistake: `npm install -g .` for CloudCLI

Symptom:

- `cloudcli` existed in `/usr/local/bin`
- but the target under `/usr/local/lib/node_modules/@siteboon/...` was broken

Root cause:

- npm created a global symlink back to the source tree
- the source tree was deleted later in the Dockerfile

Fix:

- `npm pack`
- install tarball globally

### Mistake: parsing `npm pack` output directly

Symptom:

- tarball filename parsing broke
- weird file names including `.git can't be found`

Root cause:

- upstream `prepare` / `husky` output polluted stdout

Fix:

- do not parse stdout dynamically
- derive tarball filename from package version
- run `npm pack` quietly

### Mistake: validation port allocation loop

Symptom:

- validation appeared to hang forever

Root cause:

- `find_free_port()` reused `PROXY_PORT` once it was set
- the same helper was then reused for SSH and Web port assignment
- duplicate-port avoidance loop never terminated

Fix:

- keep `find_free_port()` for `PROXY_PORT` semantics
- add a separate `random_free_port()` helper for SSH/Web ports

### Mistake: checking Web UI too early

Symptom:

- `docker-web-ui` failed with `curl: (52) Empty reply from server`

Root cause:

- TCP port was open before HTTP was truly ready

Fix:

- keep the TCP wait
- then poll for actual HTTP success both:
  - from the host port
  - from container-local `127.0.0.1:3001`

### Mistake: assuming host HTTP failure meant service failure

Symptom:

- early host-side `curl` failed

Root cause:

- timing race; service had not finished startup

Fix:

- inspect:
  - `docker logs`
  - `ss -lntp`
  - in-container local HTTP

Only then decide whether the problem is:

- service startup
- host publishing
- or just readiness timing

## Useful Debugging Moves

These were especially useful.

### 1. Manual protected stack check

When automated validation was noisy or ambiguous, the fastest path to truth was:

- start a clean isolated Docker stack manually
- use a pinned local image
- use a local SOCKS5 stub
- run:
  - `cac docker create`
  - `cac docker start`
  - `cac docker status`
  - `docker exec <container> cac-check`

This quickly answers:

- is the product broken?
- or is the test harness broken?

### 2. Check the container directly

Useful commands:

- `docker logs --tail 200 <container>`
- `docker exec <container> ss -lntp`
- `docker exec <container> ps -ef`
- `docker exec <container> cac-check`
- `docker exec <container> sh -lc 'wget -S -O - http://127.0.0.1:3001'`

### 3. Trace the validation harness with `bash -x`

This directly exposed:

- the infinite loop in port assignment

It is the best tool when the validation shell itself appears hung.

### 4. Keep Docker-mode priorities explicit

When deciding whether something is "good enough", use this order:

1. privacy/network correctness
2. runtime identity correctness
3. Web functionality

Never invert that order.

## What Was Proven By Validation

### Automated validation

The repo-local validation now passes with:

- `13` pass
- `0` fail
- `0` warn

This includes:

- original Docker-mode checks
- fail-closed behavior
- child Docker wrapper behavior
- Web UI reachability

### Manual protected validation

The protected stack also passed `cac-check`, including:

- `TUN`
- `DNS`
- `LEAK`
- `TCP`
- `HTTP`
- `EXIT`
- `GEO`
- `CAC`
- `HOST`
- `USER`
- `PID1`
- `SSHD`
- `TRACE`

This was the most important confirmation for this phase.

## Update Workflow Tips

### When CloudCLI updates

Always check in this order:

1. `server/utils/cac-paths.js`
2. files listed under `CAC-PATH-001`
3. any new direct `os.homedir()/.claude*` usage
4. any new direct Claude CLI spawn paths
5. PTY shell command generation

Suggested search patterns:

- `.claude`
- `.claude.json`
- `spawn('claude'`
- `spawn("claude"`
- `claude --resume`
- `CLAUDE_CLI_PATH`

### When HolyClaude updates

Look only at the Web/runtime overlap:

- CloudCLI version change
- any patch applied to vendored CloudCLI
- `WORKSPACES_ROOT`
- `HOME`
- `DISPLAY`
- plugin/WebSocket fixes
- browser/runtime package changes

Do not blindly mirror their whole container architecture.

## Remaining Known Future Work

- Evaluate whether HolyClaude's WebSocket plugin patch is still needed for the
  pinned CloudCLI version when plugin support is introduced
- If Web Terminal plugin is enabled later, re-test:
  - plugin proxy behavior
  - binary/text WebSocket frame handling
- If more CloudCLI code paths begin touching Claude runtime state, extend
  `cac-paths.js` rather than adding new ad hoc path logic

## Rule Of Thumb

If a change makes Web behavior nicer but weakens `cac`'s privacy/runtime model,
reject the change.

If a change makes `cac` compatibility explicit and future upgrades easier,
prefer it even if it adds a small abstraction layer.
