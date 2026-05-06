# Testing

This repo now has a repeatable local validation entrypoint:

```bash
bash scripts/validate.sh
```

The validation entrypoint now supports focused suites as well:

```bash
bash scripts/validate.sh --suite fast
bash scripts/validate.sh --suite web
bash scripts/validate.sh --suite security
bash scripts/validate.sh --suite full
```

Long-running steps also emit periodic heartbeat lines such as:

```text
[INFO] docker-create still running (60s)
```

That is intentional and helps distinguish a real hang from a slow local image build or browser regression step.

The script is designed for developer workstations and validates the current repo without touching your default `cac docker` stack:

- Rebuilds `cac` from `src/`
- Parses the JS hooks with `node --check`
- Runs an isolated CLI smoke test in a temp `HOME`
- Creates an isolated Docker validation worktree
- Starts a local SOCKS5 stub with `docker/dev-socks5.py`
- The local SOCKS5 stub can optionally chain through a real host-side upstream proxy via `CAC_VALIDATE_UPSTREAM_PROXY`
- Uses a unique `COMPOSE_PROJECT_NAME`, container names, and control subnet
- Exercises `cac docker create/start/status/check/stop`
- Verifies the Web UI is reachable on the published host port and inside the container
- Verifies child-container Docker access through the sidecar wrapper
- Verifies host port forwarding via `cac docker port`
- Verifies fail-closed behavior by stopping the local proxy stub and checking that egress fails

## Current baseline

As of April 28, 2026, the layered validation runs complete successfully:

- `bash scripts/validate.sh --suite fast`
- `bash scripts/validate.sh --suite web --keep-workdir`
- `bash scripts/validate.sh --suite security --keep-workdir`
- `bash scripts/validate.sh --suite full --keep-workdir`

Latest `full` result: `17` pass / `0` fail / `0` warn.

The old single-entrypoint run still works and is now equivalent to:

```bash
bash scripts/validate.sh --suite full --keep-workdir
```

## CI

The main CI workflow now runs the same validation script on `ubuntu-latest`:

- `bash scripts/validate.sh --keep-workdir`
- uploads `/tmp/cac-validate-*` as workflow artifacts

That keeps local and CI validation aligned instead of maintaining a separate Docker test path.

## Useful options

```bash
# Build + CLI only
bash scripts/validate.sh --skip-docker

# Same as --skip-docker, but explicit
bash scripts/validate.sh --suite fast

# Web-only regression slice
bash scripts/validate.sh --suite web

# Security / network / wrapper slice
bash scripts/validate.sh --suite security

# Keep temp logs and workdirs for debugging
bash scripts/validate.sh --keep-workdir

# Force a specific local proxy port and control subnet
bash scripts/validate.sh --proxy-port 17910 --subnet 172.28.245.0/24

# Let the validation SOCKS stubs chain through a real local proxy
CAC_VALIDATE_UPSTREAM_PROXY=socks5h://127.0.0.1:17891 \
  bash scripts/validate.sh --suite full --keep-workdir
```

## Post-release housekeeping

When a release is finished and there is no immediate follow-up validation or
development work planned, run:

```bash
bash scripts/post-release-cleanup.sh
```

This removes validation scratch directories, repo-local Python caches, and
unused Docker images/build cache while intentionally preserving:

- running containers
- Docker volumes
- persisted Claude state under `docker/data` or `CAC_DATA`
- `dist/` release assets

Use `--dry-run` to preview:

```bash
bash scripts/post-release-cleanup.sh --dry-run
```

## Coverage

### Automated by `scripts/validate.sh`

- `build.sh` output generation
- JS syntax for `src/relay.js` and `src/fingerprint-hook.js`
- Auto-init and wrapper generation in an isolated `HOME`
- `cac env create` with a preseeded fake Claude version
- Docker image build / compose bring-up
- Local bridge-mode stack startup with a SOCKS5 stub
- Web UI reachability on the published host port and on container-local `127.0.0.1:3001`
- `cac-check` inside the main container
- Child `docker run` path rewrite and proxy env injection
- Host-to-container port forwarding
- Fail-closed network behavior after proxy loss

### Suite intent

- `fast`
  - build output generation
  - syntax / parser checks
  - isolated CLI smoke test
- `web`
  - Docker bring-up
  - port auto-fallback
  - Web UI reachability
  - no-login mode
  - shell `Disconnect` regression
- `security`
  - Docker bring-up
  - `cac-check`
  - child-container wrapper / proxy-bridge
  - host port forwarding
  - fail-closed behavior
- `full`
  - runs `fast + web + security`

### Manual follow-up required

- Real Claude OAuth login and interactive `claude` use
- Real upstream proxy providers beyond the local SOCKS5 stub
- Host environments where direct IPv4 egress is unavailable unless a real local upstream proxy is supplied
- Remote Linux `macvlan` mode
- Real workspace child-container workloads from Claude Code
- Docker daemon proxy behavior on the host or Docker Desktop

## Failure history and fixes

The validation work uncovered three concrete Docker-mode failures that are now fixed:

1. `docker/entrypoint.sh` could exit immediately after profile creation.
Reason:
`apply_cherny_identity()` only populated the first field from the JSON template, then returned the status of a false `[[ -n "$session_alias" ]]` test.
Fix:
The function now uses `mapfile` to read all fields and ends with an explicit `return 0`.

2. `cac docker port` was unreliable in local/Docker Desktop mode.
Reason:
The old implementation ran a host-side `socat`/Python relay directly to the container bridge IP, which is not a stable host-routable path on Docker Desktop.
Fix:
Local mode now creates a helper container on the compose network and publishes `127.0.0.1:<port>` from that helper, while remote/macvlan mode keeps the host-side relay path.

3. `cac docker check` could fail before completing network probes.
Reason:
Running long network checks through an attached `docker exec` path was unstable in this environment.
Fix:
`cmd_docker.sh` now launches `cac-check` inside the container in the background, waits for a result file, then prints the captured output and return code.

## Validation harness issues and mitigations

Two additional problems showed up while building the validation harness itself:

1. Different repo copies collided on the default Compose project namespace because the compose files live under `docker/`.
Mitigation:
The validation script always uses a unique `COMPOSE_PROJECT_NAME` and a temp worktree.

2. Parallel Docker validation stacks could request overlapping bridge subnets.
Mitigation:
The validation script now probes for a free control subnet before writing `docker/.env`, and you can still override it with `--subnet`.

3. `docker/templates/` was already a real runtime dependency but was easy to treat like local scratch data.
Mitigation:
`docker/templates/README.md` now marks the directory as a version-controlled runtime asset, and `scripts/validate.sh` fails immediately if the required template files are missing or malformed.

## Remote/macvlan validation checklist

Run these on a native Linux Docker host after `cac docker setup` selects `remote` mode:

1. Confirm `docker/.env` contains `DEPLOY_MODE=remote`, `HOST_INTERFACE`, `MACVLAN_SUBNET`, `MACVLAN_GATEWAY`, `MACVLAN_IP`, and `SHIM_IP`.
2. Run `cac docker create && cac docker start`.
3. Verify the host shim exists:

```bash
ip link show cac-docker-shim
ip route get "$(grep '^MACVLAN_IP=' docker/.env | cut -d= -f2)"
```

4. Run `cac docker check` and confirm `TUN`, `DNS`, `LEAK`, `TCP`, `HTTP`, `EXIT`, `CAC`, and `HOST` all pass.
5. Run `cac docker port <port>` for a service listening inside the container and confirm the host can reach it.
6. Stop the upstream proxy and confirm `cac docker check` fails instead of silently falling back to direct host egress.
7. Restart the proxy and confirm the container recovers after `cac docker restart`.

## Notes

- The validation script intentionally prepends the validation worktree to `PATH`. `cmd_docker` discovers its `docker/` directory via `command -v cac`, so the repo under test must resolve first.
- The script uses a unique Compose project name because the compose files live under `docker/`; without an explicit project name, multiple repo copies collide on the default `docker` project namespace.
- If `shellcheck` is unavailable, the script keeps running and reports the skip in the build step log.
