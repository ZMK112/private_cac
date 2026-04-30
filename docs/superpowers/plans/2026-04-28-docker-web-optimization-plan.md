# Docker Web Optimization Plan

## Goal

Improve the current `cac docker` Web branch incrementally without weakening:

- Docker-mode privacy protection
- network isolation
- fail-closed behavior
- current Web no-login / Disconnect / proxy-bridge guarantees

## Execution Rule

- Do one optimization item at a time.
- After each item, run the smallest validation set that can prove the change is real.
- Do not stack multiple unverified optimizations together.
- If a change touches Docker runtime, proxying, auth, or Web shell behavior, validation is mandatory before moving on.

## Current Priority Order

### P0. Project Organization

- Status: completed
- Scope:
  - remove obvious workspace noise
  - keep tracking in a single plan file
  - make optimization status easy to resume later
- Validation:
  - `git status --short` is readable
  - no accidental cache artifacts remain tracked/untracked

### P1. Build-Proxy Failure Guidance

- Status: completed
- Reason:
  - users frequently assume `PROXY_URI` also applies to image builds
  - current behavior is correct by design, but failure feedback is not actionable enough
- Scope:
  - keep default build behavior unchanged
  - improve `cac docker create/start` failure hints when image builds cannot reach external downloads
  - make `BUILD_PROXY` guidance explicit and copyable
- Validation:
  - `bash build.sh`
  - `bash scripts/validate.sh --skip-docker`

### P2. Validation Layering

- Status: completed
- Reason:
  - `scripts/validate.sh` is already powerful but too monolithic
- Scope:
  - separate fast checks from heavy Docker/Web checks
  - preserve current coverage while making failures easier to localize
- Validation:
  - fast path passes independently
  - full path still passes unchanged

### P3. CloudCLI Upstream Upgrade Automation

- Status: completed
- Reason:
  - current upstream tracking is documented, but still mostly manual
- Scope:
  - add helper scripts for upstream audit / patch tracking consistency
- Validation:
  - tracking metadata stays consistent
  - local patch list remains reproducible

## Deferred / Constrained Items

These are intentionally not first, because they interact with product requirements already chosen on this branch:

- tightening LAN exposure defaults
- changing no-login Web behavior
- changing default SSH exposure

For this branch, those must stay compatible with the current “shared LAN / easy Web access” direction unless requirements change.

### P4. Actionable Risk + Build Guidance

- Status: completed
- Reason:
  - defaults stay intentionally convenient on this branch, so the remaining leverage is clearer CLI/doc guidance
- Scope:
  - make LAN/no-login exposure warnings more actionable
  - sync `BUILD_PROXY` guidance into the command and guide docs
- Validation:
  - `bash build.sh`
  - `bash scripts/validate.sh --suite fast`

### P5. Validation Progress Visibility

- Status: completed
- Reason:
  - long local image builds and browser checks can be silent for tens of seconds
  - silent suites look like hangs even when they are healthy
- Scope:
  - keep validation behavior unchanged
  - add periodic progress heartbeats for long-running steps
- Validation:
  - `bash -n scripts/validate.sh`
  - `bash scripts/validate.sh --suite fast`
  - `bash scripts/validate.sh --suite web --keep-workdir`

### P6. CloudCLI Upgrade Report Modes

- Status: completed
- Reason:
  - `--check` is enough for a gate, but not enough for humans rebasing patches onto a new CloudCLI upstream
- Scope:
  - add readable report modes to the CloudCLI upstream audit helper
  - make it easy to inspect a single patch and its touched files without scanning markdown manually
- Validation:
  - `python3 scripts/cloudcli-upstream-audit.py --report --patch CAC-SHELL-001`
  - `python3 scripts/cloudcli-upstream-audit.py --json`
  - `python3 scripts/cloudcli-upstream-audit.py --check`
  - `bash scripts/validate.sh --suite fast`

### P7. Docker Command Source Split

- Status: completed
- Reason:
  - `src/cmd_docker.sh` had become the highest-maintenance shell file in the repo
  - high-value project cleanup here directly improves future safety and reviewability
- Scope:
  - split Docker common helpers, runtime/build helpers, and port-forward helpers into dedicated source files
  - keep runtime behavior unchanged
- Validation:
  - `bash build.sh`
  - `bash -n src/cmd_docker_common.sh`
  - `bash -n src/cmd_docker_runtime.sh`
  - `bash -n src/cmd_docker_ports.sh`
  - `bash -n src/cmd_docker.sh`
  - `bash scripts/validate.sh --suite full --keep-workdir`

## Progress Log

### 2026-04-28

- Created optimization tracking plan.
- Decided to optimize in small verified steps instead of batching changes.
- Added repo hygiene guardrails for Python cache artifacts.
- Cleared the current `docker/lib/__pycache__` workspace noise.
- Improved Docker build failure guidance so local source builds now explain the difference between `PROXY_URI` and `BUILD_PROXY`, and print a copyable `BUILD_PROXY=` suggestion when possible.
- Added regression checks for build-proxy suggestion derivation.
- Validation after P1:
  - `bash build.sh`
  - `bash scripts/validate.sh --skip-docker`
  - result: `2 pass / 0 fail / 0 warn`
- Added validation suites: `fast`, `web`, `security`, `full`.
- Validation during P2:
  - `bash -n scripts/validate.sh`
  - `bash scripts/validate.sh --suite fast`
  - `bash scripts/validate.sh --suite web --keep-workdir`
  - `bash scripts/validate.sh --suite security --keep-workdir`
  - `bash scripts/validate.sh --suite full --keep-workdir`
  - suite results:
    - `fast`: `2 pass / 0 fail / 0 warn`
    - `web`: `10 pass / 0 fail / 0 warn`
    - `security`: `12 pass / 0 fail / 0 warn`
    - `full`: `17 pass / 0 fail / 0 warn`
- Added `scripts/cloudcli-upstream-audit.py` to machine-check:
  - required upstream metadata
  - required CloudCLI patch IDs
  - patch status expectations
  - referenced file existence
- Filled patch-log gaps for:
  - no-login platform mode
  - manual Disconnect behavior
  - disabled update checks
- Validation during P3:
  - `python3 scripts/cloudcli-upstream-audit.py --check`
  - `bash scripts/validate.sh --suite fast`
  - result: `2 pass / 0 fail / 0 warn`
- Improved LAN/no-login exposure warnings so the CLI now prints direct lockdown snippets instead of only generic caution text.
- Synced `BUILD_PROXY` guidance into the command and guide docs.
- Validation during P4:
  - `bash build.sh`
  - `bash scripts/validate.sh --suite fast`
  - result: `2 pass / 0 fail / 0 warn`
- Added heartbeat progress lines for long-running validation steps.
- First heartbeat attempt briefly regressed background-process steps because it wrapped each step in a subshell; fixed by keeping the step itself in the foreground and running only the heartbeat loop in the background.
- Validation during P5:
  - `bash -n scripts/validate.sh`
  - `bash scripts/validate.sh --suite fast`
  - `bash scripts/validate.sh --suite web --keep-workdir`
  - results:
    - `fast`: `2 pass / 0 fail / 0 warn`
    - `web`: `10 pass / 0 fail / 0 warn`
- Extended the CloudCLI upstream audit helper with:
  - `--report`
  - `--report --patch <PATCH-ID>`
  - `--json`
- This keeps the upgrade path readable without scanning long markdown files manually.
- Validation during P6:
  - `python3 scripts/cloudcli-upstream-audit.py --report --patch CAC-SHELL-001`
  - `python3 scripts/cloudcli-upstream-audit.py --json`
  - `python3 scripts/cloudcli-upstream-audit.py --check`
  - `bash scripts/validate.sh --suite fast`
  - result: `2 pass / 0 fail / 0 warn`
- Split Docker shell sources into:
  - `src/cmd_docker_common.sh`
  - `src/cmd_docker_runtime.sh`
  - `src/cmd_docker_ports.sh`
  - `src/cmd_docker.sh`
- `src/cmd_docker.sh` itself is now down to `501` lines, from the previous `1476`.
- Validation during P7:
  - `bash build.sh`
  - `bash -n src/cmd_docker_common.sh`
  - `bash -n src/cmd_docker_runtime.sh`
  - `bash -n src/cmd_docker_ports.sh`
  - `bash -n src/cmd_docker.sh`
  - `bash scripts/validate.sh --suite full --keep-workdir`
  - result: `17 pass / 0 fail / 0 warn`
