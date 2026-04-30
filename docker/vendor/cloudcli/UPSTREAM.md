# CloudCLI Upstream Tracking

- Upstream repository: `https://github.com/siteboon/claudecodeui`
- Vendored path: `docker/vendor/cloudcli/upstream`
- Source acquisition method: `git clone`
- Initial pinned tag: `v1.26.3`
- Initial pinned commit: `ebd1c0d`
- Initial local vendor import date: `2026-04-07`

Why `v1.26.3` first:

- aligns with the CloudCLI version already examined in HolyClaude
- patch points are easier to compare against HolyClaude's known Web fixes

Upgrade rule:

- update this file on every upstream bump before local patches are rebased
- run `python3 scripts/cloudcli-upstream-audit.py --check` after editing this file
  or `PATCHES.md`
- useful report modes:
  - `python3 scripts/cloudcli-upstream-audit.py --report`
  - `python3 scripts/cloudcli-upstream-audit.py --report --patch CAC-SHELL-001`
  - `python3 scripts/cloudcli-upstream-audit.py --json`
