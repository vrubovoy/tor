# Security Policy

## Supported versions

tor is deployed continuously from `main` — there are no maintained release
branches. Security fixes land on `main` and that is the only supported
version.

## Reporting a vulnerability

Please do not open a public issue for security vulnerabilities. Instead,
use GitHub's private reporting flow:

1. Go to the [Security tab](../../security) of this repository.
2. Click "Report a vulnerability".
3. Describe the issue, including reproduction steps if you have them.

This is a small, mostly-solo project, so response time is best-effort, not
contractual — but you can expect an initial reply within a few days.

## Scope

tor terminates TLS and routes every request for the whole platform, so
misconfiguration here has platform-wide impact. In scope: anything in the
Caddyfile that could expose a service's internal port, route traffic to
the wrong backend, downgrade or misconfigure TLS (weak ciphers, missing
auto-HTTPS), leak VAPID private material into a frontend, widen a Browser
Push endpoint allowlist, expose Wächter's Docker agent outside its internal
network, bypass restart labels, or otherwise bypass the single-entry-point
design.
