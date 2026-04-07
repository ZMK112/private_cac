# s6 Services

This directory contains the `s6-overlay` service definitions used by the
`cac docker` Web integration.

Initial service scope:

- `cloudcli`: browser-facing CloudCLI service
- `xvfb`: virtual display for Chromium / Playwright

Design rule:

- `cac docker` runtime initialization still happens in `entrypoint.sh`
- `s6` only starts after TUN, persona, runtime env, and active-env compatibility
  mapping are ready
- if `cac` protection semantics and Web convenience conflict, `cac` protection
  semantics win
