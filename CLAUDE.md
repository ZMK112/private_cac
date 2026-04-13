# cac Project Memory

## Current Direction

- Goal: add Web access to `cac docker` so Claude can be used from the browser while keeping `cac`'s privacy protection, network isolation, and Docker-mode runtime model.
- Scope: support the current active env only. Web-side profile switching is not required.
- Additional runtime requirement: the existing `cac docker` container should also provide `Xvfb`, `Chromium`, and `Playwright`.
- Service supervision decision: use `s6` from the beginning rather than adding it later.
- Current Web UX target: Docker Web UI should open without a manual CloudCLI login step.
- Current host-port target: if default SSH/Web host ports are occupied, Docker mode should automatically advance to the next free ports and persist them.

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
- This should make future HolyClaude Web-related updates easier to port with minimal churn.
- Detailed analysis and patch map notes live in `docs/superpowers/plans/2026-04-07-cloudcli-cac-web-analysis.md`.
- Proposed implementation and upstream-tracking workflow live in `docs/superpowers/plans/2026-04-07-cloudcli-cac-web-implementation-plan.md`.
- Debugging tips, migration pitfalls, and validation mistakes live in `docs/superpowers/plans/2026-04-07-cloudcli-cac-web-dev-notes.md`.

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
- Current local validation result for this branch: `16 pass / 0 fail / 0 warn`
