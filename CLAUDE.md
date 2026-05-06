# cac Project Memory

## Compact Resume

- Branch: `feature/cloudcli-cac-web`
- Workspace state: dirty, many local changes not yet committed/released
- Docker runtime: OrbStack is working again; `docker version` was confirmed healthy
- Core product status:
  - Web UI inside protected main container is implemented
  - no-login Web mode is implemented
  - Disconnect behavior is implemented
  - child-container `proxy-bridge` is implemented
  - `socks://BASE64(user:pass)@host:port#tag` and `ss://...` real-proxy flows were both validated end-to-end
  - `cac docker setup` now supports safer runtime proxy switching
  - `cac docker setup` now supports shell selection (`bash` / `zsh`)
  - `CAC_DATA` switch now requires explicit confirmation when it would move persisted Claude state
  - reinstall/rebuild is now documented and messaged as preserve-by-default for Claude credentials/history
  - `cac docker check` now streams progressively and prints a non-gating `SPD` speed line

- Highest-confidence validation already completed:
  - `bash build.sh`
  - shell/Python syntax checks
  - `bash scripts/validate.sh --suite fast`
  - isolated real-proxy integration using two user-provided working share-link proxies:
    - one `socks://BASE64(user:pass)@host:port#tag`
    - one `ss://...`
  - both passed:
    - setup-before-create
    - runtime proxy switch on a running stack
    - `cac docker check`

- Remaining blocker before commit/release:
  - no blocker remains at the validation level
  - latest full result is:
    - `19 pass / 0 fail / 0 warn`
    - logs captured in a temporary `/tmp/cac-validate-logs.*` directory during validation
  - the previous unstable item `docker-setup-proxy-switch` is now fixed

- Most recent concrete fix before this note:
  - `cac docker setup` no longer overwrites the chosen Docker control subnet/IPs back to fixed `172.31.255.0/24`
  - this was causing network overlap during validation restarts

- Next resume actions:
  1. read this file first
  2. inspect current `git status --short`
  3. if you need to revalidate on this host, use a temporary upstream proxy container or a real local proxy listener
  4. next meaningful step is commit/tag/release preparation

- Do not repeat these mistakes:
  - do not treat validation-stub networking problems as product regressions before testing with real proxies
  - do not implicitly switch `CAC_DATA`
  - do not introduce destructive cleanup of Claude persisted state by default
  - do not release from this branch until full validation is green, even if real-proxy manual tests already pass
  - after a release is finished and there is no immediate next validation/dev task, run `bash scripts/post-release-cleanup.sh` to remove temporary garbage and unused Docker cache

## Current Direction

- Goal: add Web access to `cac docker` so Claude can be used from the browser while keeping `cac`'s privacy protection, network isolation, and Docker-mode runtime model.
- Scope: support the current active env only. Web-side profile switching is not required.
- Additional runtime requirement: the existing `cac docker` container should also provide `Xvfb`, `Chromium`, and `Playwright`.
- Service supervision decision: use `s6` from the beginning rather than adding it later.
- Current Web UX target: Docker Web UI should open without a manual CloudCLI login step.
- Current host-port target: if default SSH/Web host ports are occupied, Docker mode should automatically advance to the next free ports and persist them.

## Current Branch Snapshot

- Active branch: `feature/cloudcli-cac-web`
- Base branch: `master`
- Current state: the branch is well past MVP; Web mode, proxy-bridge, no-login, Disconnect protection, validation layering, and Docker shell refactoring are all implemented locally
- Important: the workspace still contains uncommitted changes; do not assume the last pushed branch tip already includes the latest optimization wave
- New in the latest local wave:
  - `cac docker setup` now supports a safer proxy reconfiguration flow for already-running containers
  - Docker-mode shell selection is being promoted from hardcoded `bash` toward an explicit `setup` choice (`bash` or `zsh`)
  - share-link compatibility was expanded to include `socks://BASE64(user:pass)@host:port#tag`

## Current Progress Snapshot

Already implemented and locally verified on this branch:

- Docker Web UI inside the protected main container
- `s6` supervision for `CloudCLI` and `Xvfb`
- `Chromium` / `Playwright` / Web runtime packages in the main image
- active-env Claude state compatibility through runtime mapping into `HOME/.claude*`
- Docker no-login platform mode
- shell `Disconnect` stays disconnected until the user explicitly reconnects
- auto-fallback for occupied SSH/Web host ports
- child-container `proxy-bridge` sidecar for share-link upstream protocols
- CloudCLI upstream audit/report tooling
- layered validation suites: `fast`, `web`, `security`, `full`
- Docker shell source split:
  - `src/cmd_docker_common.sh`
  - `src/cmd_docker_runtime.sh`
  - `src/cmd_docker_ports.sh`
  - `src/cmd_docker.sh`

Most recent high-value refactor result:

- `src/cmd_docker.sh` reduced from `1476` lines to `501`
- the split still passes full validation end-to-end

Latest in-progress local changes that are implemented in code but not yet fully revalidated end-to-end:

- `cac docker setup` now saves new proxy settings first and, if a container is already running, should prompt before restarting to apply them
- proxy setup quick-check logic was added:
  - standard proxy URLs and compact `host:port` forms get a host-side reachability probe
  - share links such as `ss://`, `vmess://`, `vless://`, `trojan://`, and `socks://...` only get basic upstream endpoint reachability checks
- new accepted proxy input example:
  - `socks://BASE64(user:pass)@host:port#tag`
- Docker image and runtime shell work are in progress:
  - image now installs `zsh`
  - `cac docker setup` now records a preferred shell (`/bin/bash` or `/bin/zsh`)
  - `cac docker enter` was changed from hardcoded `bash` to the configured shell
- Docker data safety additions are now implemented locally:
  - `cac docker setup` warns and requires explicit confirmation before switching `CAC_DATA` to a different directory when that would move persisted Claude state
  - `cac docker status` prints both the raw `CAC_DATA` value and the resolved absolute data path
  - `install.sh` now prints an explicit preserve-mode notice for existing Docker Claude state
- `cac docker check` ergonomics are now improved locally:
  - outer `cac docker check` output is streamed incrementally instead of printing only at the end
  - a non-gating `SPD` line reports proxy download speed without affecting pass/fail
- Local Docker control-subnet handling was corrected:
  - `cac docker setup` no longer overwrites the chosen control subnet/IPs back to a fixed `172.31.255.0/24`
- Real-proxy validation result:
  - direct isolated tests using the user-provided real `socks://...` and `ss://...` share links both passed end-to-end
  - setup-before-create and running-stack proxy switch both worked against those real proxies

Only the fast suite has been rerun after these latest changes:

- `bash scripts/validate.sh --suite fast` → pass

The full Docker suite has **not** been re-established after the latest proxy/zsh changes because the host Docker runtime was being migrated from Docker Desktop to OrbStack during this session.

## Priority Rule

- `cac docker` safety, privacy protection, network isolation, and runtime semantics have higher priority than every new Web feature.
- If a Web integration choice weakens or complicates `cac`'s protection model, the protection model wins.
- Web functionality is acceptable only if the original `cac docker` protection and network-management tests still pass strictly.

## Preview

- `Web 使用 Docker 容器中的 Claude Code`

## Working Assumptions

- `cac docker` remains the foundation. Its TUN path, persona generation, workspace mount, SSH access, Docker wrapper, and current runtime env model should stay intact.
- The Web layer is an overlay on top of `cac docker`, not a full transplant of HolyClaude.
- `CloudCLI` should run inside the main `cac` container so its outbound traffic stays on the main container's protected network path.

## Architecture Direction

- Run `CloudCLI` inside the main `cac docker` container.
- Run `Xvfb` inside the same container.
- Install `Chromium`, `Playwright`, and required fonts/packages into the `cac docker` image.
- After `cac docker` finishes TUN + persona + runtime env initialization, expose the current active env's `.claude` as `HOME/.claude` for Web compatibility.
- Also handle `.claude.json` consistently, because CloudCLI touches it directly.
- Set `WORKSPACES_ROOT=/workspace`, `DISPLAY=:99`, and keep CloudCLI state under persistent home storage rather than `/workspace`.
- Use Docker Web UI no-login platform mode rather than requiring manual CloudCLI auth in the browser.
- Keep host port assignment user-friendly by printing the resolved Web URL and auto-advancing occupied SSH/Web ports.
- Child containers should no longer try to consume upstream proxy protocols directly. They must go through a local authenticated `proxy-bridge` sidecar that converts `PROXY_URI` into standard HTTP/SOCKS proxy endpoints.

## Why This Direction

- `HolyClaude` is primarily a prebuilt AI workstation with a Web UI.
- `cac` is primarily a Claude Code environment/privacy manager; Docker mode is one runtime mode, not the whole product.
- The target is not to replace `cac` with HolyClaude. The target is to graft HolyClaude's Web capability onto `cac docker` while keeping `cac` as the protected runtime base.

## Key Risks

- CloudCLI hardcodes many paths under `os.homedir()/.claude` and `os.homedir()/.claude.json`, so active-env mapping is mandatory.
- CloudCLI uses both CLI/PTY flows and Claude SDK flows. Browser usage must not silently bypass `cac`'s wrapper semantics where protection depends on runtime env injection.
- A simple PATH assumption is not enough. CloudCLI startup should be explicitly bound to the `cac` runtime environment.
- CloudCLI's database should not live on `/workspace`; persistent home storage is safer.
- If this is distributed inside the image, remember CloudCLI licensing is GPL-3.0 while `cac` itself is MIT.
- Any change that touches startup, routing, DNS, proxying, persona files, `HOME`, or Claude session paths may affect `cac`'s original privacy guarantees and must be treated as high-risk.

## Maintenance Strategy

- Follow HolyClaude's Web overlay changes, not the whole HolyClaude container architecture.
- Keep the integration thin:
  - CloudCLI install/version
  - CloudCLI patches that affect Web behavior
  - `WORKSPACES_ROOT` / runtime env glue
  - `Xvfb` / `Chromium` / `Playwright`
  - startup/health behavior
- Two Web UX behaviors are mandatory compatibility requirements for future upstream changes:
  - no-login Docker Web mode must keep working; opening the Web UI should go straight into the app instead of stopping on CloudCLI auth pages
  - shell `Disconnect` must keep the shell disconnected until the user explicitly clicks `Connect`
- Child-container proxy compatibility is also mandatory for future upstream changes:
  - share-link protocols such as `ss://`, `vmess://`, `vless://`, and `trojan://` must continue to work for child-container workflows through the `proxy-bridge`
- Docker upgrade data safety is mandatory:
  - image rebuilds, container recreation, and `bash install.sh --local --yes` reinstalls must preserve Claude login state, credentials, memory, and session history by default
  - destructive cleanup of persisted Docker data must never be implicit; users must have to delete the Docker data directory manually on purpose
- If upstream CloudCLI, HolyClaude, or related Web/runtime layers are refactored or updated, these two behaviors must be revalidated and, if broken, fixed before the update is considered complete.
- If Docker-mode networking or child-container wrapper logic changes, revalidate both the `proxy-bridge` path and the Web no-login/Disconnect behaviors together.
- This should make future HolyClaude Web-related updates easier to port with minimal churn.
- Detailed analysis and patch map notes live in `docs/superpowers/plans/2026-04-07-cloudcli-cac-web-analysis.md`.
- Proposed implementation and upstream-tracking workflow live in `docs/superpowers/plans/2026-04-07-cloudcli-cac-web-implementation-plan.md`.
- Debugging tips, migration pitfalls, and validation mistakes live in `docs/superpowers/plans/2026-04-07-cloudcli-cac-web-dev-notes.md`.
- CloudCLI upstream metadata consistency can now be checked with `python3 scripts/cloudcli-upstream-audit.py --check`.

## Current Resume Point

If a new session resumes from here, assume:

- the current optimization wave is complete through `P7` in `docs/superpowers/plans/2026-04-28-docker-web-optimization-plan.md`
- the next sensible action is **not** to release immediately
- the next blocking task is to restore a working host Docker runtime under OrbStack, then rerun full validation
- only after full validation is green should the branch be committed, pushed, and released

Unless requirements change, do not reopen already-settled architecture choices such as:

- Web UI inside the main protected container
- no-login Docker Web mode
- `proxy-bridge` for child containers
- `s6` supervision

## s6 Note

- `s6` is a small process supervisor commonly used in multi-service Docker containers.
- Decision: use `s6` from V1.
- Reason: `CloudCLI + Xvfb + future Web/runtime services` should start under a supervised, explicit service model instead of shell-only backgrounding.

## Recommended Phasing

1. MVP:
   - add CloudCLI
   - add `Xvfb` / `Chromium` / `Playwright`
   - map active env `.claude` to `HOME/.claude`
   - expose a Web port
   - run Web services under `s6`
2. Hardening:
   - verify Web flows respect `cac` protection semantics as much as practical
   - add health/readiness checks
   - tighten persistence and startup behavior
3. Productization:
   - keep HolyClaude Web-side compatibility easy to track

## Current Validation Gate

- Validation must cover:
  - original Docker privacy/network checks
  - fail-closed behavior
  - child Docker wrapper behavior
  - Web UI reachability
  - no-login Web access
  - occupied-port auto-fallback for SSH and Web
  - shell Disconnect behavior: clicking `Disconnect` in Web UI must keep the shell disconnected until the user explicitly clicks `Connect`; switching session/project or clicking `Restart` must still allow auto-reconnect
  - child-container proxy bridge behavior: child containers must receive authenticated HTTP/SOCKS bridge URLs and still be able to egress when the upstream `PROXY_URI` is a share-link protocol
- Upstream upgrade gate:
  - whenever CloudCLI, HolyClaude Web glue, or related shell/Web runtime code changes, re-check both no-login access and Disconnect behavior as required regressions, not optional polish
- Current child-container architecture note:
  - the main container still uses TUN + sing-box directly
  - child containers now use a dedicated `proxy-bridge` sidecar instead of trying to consume `ss://` or other share links directly
- Last known-good full result before the latest proxy/zsh wave: `17 pass / 0 fail / 0 warn`
- Current validation state after the latest proxy/zsh wave:
- `fast` suite passes
- `fast` still passes after the latest `CAC_DATA` / `SPD` / streamed-check / control-subnet fixes
- `full` suite is no longer blocked by Docker runtime availability; OrbStack is running and `docker version` is healthy outside the sandbox
  - `full` suite is still not green on this host unless validation has a real upstream proxy path
  - root cause:
    - the local validation helper `docker/dev-socks5.py` is a host-side SOCKS stub
    - `cac-check` and the protected container send IPv4 literal targets such as `1.1.1.1:443`

## Post-release housekeeping

- A dedicated cleanup hook now exists:
  - `bash scripts/post-release-cleanup.sh`
- Use it only after a release is done and there is no immediate follow-up
  validation or development task.
- It is allowed to remove:
  - `/tmp/cac-validate-*`
  - `/tmp/cacmanual*`
  - `/tmp/cac-web-*`
  - `/tmp/proxy-stub-*`
  - repo-local `__pycache__`
  - unused Docker images, stopped containers, networks, and build cache
- It must not remove:
  - running containers
  - Docker volumes
  - persisted Claude state under `docker/data` or `CAC_DATA`
  - release assets under `dist/`
    - this macOS host currently does not have a usable direct IPv4 egress path for those targets, so the stub cannot relay them directly
    - this is a validation-fixture limitation on this machine, not a confirmed product regression
  - latest local mitigation:
    - `docker/dev-socks5.py` now supports `--upstream <socks5://...>` so it can chain through a real host-side proxy when needed
    - `scripts/validate.sh` now forwards `CAC_VALIDATE_UPSTREAM_PROXY` to both validation stubs
- required next step before release:
    - full validation still has one unresolved validation-layer issue around `docker-setup-proxy-switch`
    - current status:
      - with a temporary upstream SOCKS5 container, `docker-check-command`, `container-cac-check`, child-wrapper, port-forward, and fail-closed steps pass
      - the remaining unstable piece is the long-running `docker-setup-proxy-switch` validation step itself
    - only after that last full-suite issue is resolved should this branch be committed/released
- Validation ergonomics note:
  - `scripts/validate.sh` now supports `fast`, `web`, `security`, and `full` suites
  - long-running steps emit heartbeat progress lines so slow builds are easier to distinguish from hangs
- Docker CLI structure note:
  - Docker-mode shell code is no longer concentrated in a single source file
  - current split:
    - `src/cmd_docker_common.sh`
    - `src/cmd_docker_runtime.sh`
    - `src/cmd_docker_ports.sh`
    - `src/cmd_docker.sh`

## Validation Commands

Use these exact commands depending on scope:

- fast checks only:
  - `bash scripts/validate.sh --suite fast`
- Web regression slice:
  - `bash scripts/validate.sh --suite web --keep-workdir`
- security/network/proxy slice:
  - `bash scripts/validate.sh --suite security --keep-workdir`
- full end-to-end gate:
  - `bash scripts/validate.sh --suite full --keep-workdir`

Current known-good full result:

- `17 pass / 0 fail / 0 warn`

Current blocked resume sequence:

1. Ensure OrbStack is fully initialized and responsive:
   - `source ~/.zshrc`
   - `docker version`
   - `orb status`
2. Ensure a real local proxy listener exists on the host for validation chaining.
   - Example:
     - `CAC_VALIDATE_UPSTREAM_PROXY=socks5h://127.0.0.1:17891`
3. Then rerun:
   - `CAC_VALIDATE_UPSTREAM_PROXY=socks5h://127.0.0.1:<port> bash scripts/validate.sh --suite full --keep-workdir`
4. If full validation passes, then:
   - update docs/memory if needed
   - commit
   - tag/release

## Do Not Repeat These Mistakes

1. Do not treat a sandbox `PermissionError` during `validate.sh --suite web` as a product bug by default.
   - In this environment, `web` / `security` / `full` suites often need unsandboxed Docker execution.

2. Do not implement validation heartbeats by pushing the step itself into a background subshell.
   - That broke `proxy-stub` / port-blocker style steps because their child process lifecycle changed.
   - Correct pattern: keep the real step in the foreground; run only the heartbeat loop in the background.

3. Do not assume CloudCLI path compatibility currently comes from a vendored `cac-paths.js` helper.
   - On this branch, the pinned compatibility layer is primarily runtime mapping via:
     - `docker/entrypoint.sh`
     - `docker/web/cloudcli-env.sh`
   - The patch log was corrected to reflect this.

4. Do not assume `PROXY_URI` applies to image builds.
   - Runtime proxying and build-time downloads are separate.
   - Build failures around `claude.ai/install.sh` usually mean host-network or `BUILD_PROXY` issues, not TUN/runtime issues.

5. Do not let child containers consume upstream share links directly.
   - `ss://`, `vmess://`, `vless://`, `trojan://` must flow through the authenticated `proxy-bridge`.

6. Do not merge upstream CloudCLI updates without rechecking the two mandatory Web regressions:
   - no-login Web mode still bypasses auth pages
   - manual `Disconnect` still stays disconnected until explicit reconnect

7. Do not change Docker-mode networking, startup, or wrapper logic without revalidating both:
   - `proxy-bridge`
   - Web no-login / Disconnect behavior

8. Do not mistake host-runtime failures for project-code failures.
   - During this session, a full validation run failed once because the host disk was full and Docker BuildKit could not commit the image layer.
   - After that, Docker Desktop was intentionally wiped and OrbStack was installed, which means Docker availability is now an environment prerequisite before any release work continues.

9. Do not auto-restart a running Docker workspace from `cac docker setup` without an explicit confirmation prompt.
   - Restarting from the wrong host directory can silently remount `/workspace` to the current shell's directory.
   - The intended behavior is: save config first, then prompt before restart if the container is already running.

## Current Workspace State

At the time this memory was updated:

- the project contains a large but coherent uncommitted optimization wave
- key new local source files include:
  - `src/cmd_docker_common.sh`
  - `src/cmd_docker_runtime.sh`
  - `src/cmd_docker_ports.sh`
  - `scripts/cloudcli-upstream-audit.py`
  - `docs/superpowers/plans/2026-04-28-docker-web-optimization-plan.md`
  - `docs/zh/guides/docker-quickstart-simple.mdx`
- generated `cac` has already been rebuilt after the source split
- latest working-tree additions also include:
  - `docker/Dockerfile.proxy-bridge`
  - `docker/lib/bridge.py`
  - `docker/proxy-bridge-entrypoint.sh`
- latest modified files directly relevant to the current unblock path:
  - `docker/Dockerfile`
  - `docker/entrypoint.sh`
  - `docker/lib/protocols.py`
  - `src/cmd_docker.sh`
  - `src/cmd_docker_runtime.sh`
  - `scripts/validate.sh`

Host environment state at the end of this session:

- Docker Desktop data was intentionally purged to free disk space
- host free space recovered to roughly `95 GiB`
- OrbStack app is installed
- OrbStack Docker CLI path was appended to `~/.zshrc`:
  - `export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"`
- however, OrbStack was not yet responsive:
  - `docker version` timed out
  - `orb list` timed out
- therefore do not attempt release work until the host confirms OrbStack is actually ready

Before starting new work in another session:

- read this file first
- then read `docs/superpowers/plans/2026-04-28-docker-web-optimization-plan.md`
- then inspect `git status --short`
- then choose the smallest next step and validate immediately after it

## Optimization Workflow

- Current optimization tracking doc: `docs/superpowers/plans/2026-04-28-docker-web-optimization-plan.md`
- Optimization order should follow that plan unless a newly discovered bug is more urgent.
- Each optimization item must be validated before the next item starts.
- Do not batch several unverified project cleanups or UX improvements into one step.
