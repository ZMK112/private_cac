# Web Overlay

This directory contains the `cac docker` Web integration glue.

Responsibilities:

- prepare CloudCLI runtime environment
- map the current active `cac` env into the filesystem shape CloudCLI expects
- keep Web-specific logic separate from the core Docker privacy/runtime model

Key rule:

- the Web layer adapts to `cac`
- `cac` does not weaken its privacy / network model to satisfy the Web layer
