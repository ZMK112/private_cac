# Docker Templates

This directory is part of the Docker-mode runtime source tree.

These files are not local scratch data. They are consumed by:

- [docker/Dockerfile](/Users/zmk/tmp/cac/docker/Dockerfile), which copies `docker/templates` into `/usr/local/share/cherny`
- [docker/entrypoint.sh](/Users/zmk/tmp/cac/docker/entrypoint.sh), which reads the `cherny.*` files to build the canonical identity, env, prompt, and telemetry profile inside the container
- the Docker-mode docs, which describe these templates as the canonical Docker identity fixtures

Required files:

- `cherny.identity.json`
- `cherny.env.json`
- `cherny.prompt.json`
- `cherny.telemetry.json`
- `cherny.clash.yaml`

Rules:

- Keep these files under version control.
- Do not put secrets or machine-local values here.
- Update docs and validation together when these files change.
- If Docker mode starts depending on a new template file, add it here and extend `scripts/validate.sh`.
