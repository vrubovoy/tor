# tor

[![Test](https://github.com/zudaR107/tor/actions/workflows/test.yml/badge.svg)](https://github.com/zudaR107/tor/actions/workflows/test.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

Part of the [Hof platform](https://github.com/zudaR107/Hof) — a suite of
self-hosted personal services:

- [`schloss`](https://github.com/zudaR107/schloss) — home page / launcher
- [`schlussel`](https://github.com/zudaR107/schlussel) — auth: accounts, login, tokens
- [`kuvert`](https://github.com/zudaR107/kuvert) — envelope budgeting
- [`tafel`](https://github.com/zudaR107/tafel) — task/project tracking
- [`zettel`](https://github.com/zudaR107/zettel) — markdown note-taking
- [`glocke`](https://github.com/zudaR107/glocke) — in-app notification center and delivery foundation
- [`schrank`](https://github.com/zudaR107/schrank) — file storage with nested folders
- [`herold`](https://github.com/zudaR107/herold) — webmail client for external IMAP/SMTP accounts
- [`wachter`](https://github.com/vrubovoy/wachter) — server resource monitoring
- **`tor`** (this repo) — reverse-proxy gateway all of the above sit behind
- [`schloss-ui`](https://github.com/zudaR107/schloss-ui) — shared frontend components
- [`schloss-server-kit`](https://github.com/zudaR107/schloss-server-kit) — shared backend auth/CORS kit

tor ("gate" in German) is the single-entrypoint reverse-proxy gateway for
the Hof platform. It fronts every service by subdomain so nobody needs to
remember or type a port.

## How it fits into the platform

tor ships no application code of its own — just a Caddyfile and a
docker-compose.yml. It routes by `Host:` header to each app's web-facing
Compose service on internal port `80`. The current routes are:

| Public host | Compose service |
|---|---|
| `{$DOMAIN}` | `schloss` |
| `auth.{$DOMAIN}` | `schlussel-frontend` |
| `kuvert.{$DOMAIN}` | `kuvert-frontend` |
| `tafel.{$DOMAIN}` | `tafel-frontend` |
| `zettel.{$DOMAIN}` | `zettel-frontend` |
| `glocke.{$DOMAIN}` | `glocke-frontend` |
| `schrank.{$DOMAIN}` | `schrank-frontend` |
| `herold.{$DOMAIN}` | `herold-frontend` |

The API services (`schlussel`, `kuvert-backend`, `tafel-backend`,
`zettel-backend`, `glocke-backend`, `schrank-backend`, and
`herold-backend`) remain internal dependencies and are not direct
gateway targets. `wachter` has no row here at all - it has no subdomain
of its own; its data is reached through `schloss`'s own `/wachter/*`
proxy instead (see its README for why).

## Running the whole platform

Assumes the standard layout: `schlussel/`, `schloss/`, `kuvert/`, `tafel/`,
`zettel/`, `glocke/`, `schrank/`, `herold/`, `wachter/`, and `tor/` as
sibling directories. All sibling checkouts come from cloning
[`Hof`](https://github.com/zudaR107/Hof) with `--recurse-submodules`.

```sh
docker network create schloss-net   # one-time
cp .env.example .env
# Generate independent values for the five Glocke HMAC secrets, two
# Zettel/Schrank sync secrets, Herold encryption key, and Wächter agent token.
docker compose up -d --build
```

That's it — this one command starts all eight apps, Wächter, and the
gateway, via `include:` pulling in each sibling repo's own
`docker-compose.yml`. In Compose terms that is seventeen application
services plus `gateway`: seven apps have separate backend and frontend
services, Schloss is frontend-only, and Wächter has an API plus a private
Docker agent.

- `https://localhost` — Schloss (home)
- `https://auth.localhost` — Schlüssel (login/register)
- `https://kuvert.localhost` — Kuvert
- `https://tafel.localhost` — Tafel
- `https://zettel.localhost` — Zettel
- `https://glocke.localhost` — Glocke
- `https://schrank.localhost` — Schrank
- `https://herold.localhost` — Herold

`*.localhost` resolves to `127.0.0.1` automatically in every modern browser
— no `/etc/hosts` editing needed. Caddy auto-upgrades these to HTTPS; since
`localhost` can't get a real Let's Encrypt certificate, it signs them with
its own local CA instead (see below - one-time browser setup needed).

An unknown local app host such as `https://typo.localhost/path` receives its
own exact-hostname certificate from that local CA and redirects to
`https://localhost/path`. The gateway does not issue an internal-CA
certificate for an unknown production host such as `typo.example.com`:
the on-demand TLS policy denies it, so the TLS handshake fails before an
HTTP redirect or response can be sent. This prevents a production gateway
from acting as an internal-certificate oracle for arbitrary hostnames.

### Trusting the local HTTPS certificate (one-time, local dev only)

The gateway's certificates for its named localhost sites, and exact
certificates issued for unknown `*.localhost` hosts, are signed by a CA
Caddy generates and stores in the `caddy-data` volume - your browser
doesn't know about it yet, so the first visit shows a certificate warning
(`SEC_ERROR_UNKNOWN_ISSUER` in Firefox, "Not secure" in Chrome). Trust it
once per machine:

```sh
docker compose exec gateway \
  cat /data/caddy/pki/authorities/local/root.crt > caddy-local-root.crt
```

**Firefox**: `about:preferences#privacy` → scroll to Certificates → *View
Certificates* → *Authorities* tab → *Import…* → select `caddy-local-root.crt`
→ check *"Trust this CA to identify websites"* → OK. Restart Firefox.

**Chrome/system trust store** (Linux): `sudo cp caddy-local-root.crt
/usr/local/share/ca-certificates/caddy-local-root.crt.crt && sudo
update-ca-certificates` (Debian/Ubuntu; other distros use their own
equivalent), then restart the browser. macOS: import into Keychain Access
(System keychain, "Always Trust"). Windows: import via `certutil -addstore
-f "ROOT" caddy-local-root.crt` or the Certificates MMC snap-in.

This only needs to happen again if the `caddy-data` volume is ever removed
(e.g. `docker compose down -v`, or `docker volume rm caddy-data`) - that
regenerates the CA with a new key, and the old trusted entry needs
replacing (delete the old "Caddy Local Authority" entry first, then import
the new `root.crt`, or you'll see `SEC_ERROR_BAD_SIGNATURE` instead of the
usual unknown-issuer warning).

### Running a single service standalone

Each repo's own `docker-compose.yml` still works on its own for isolated
development of just that service (still needs the shared `schloss-net`
network created once, and the other services it depends on already
running, same as before tor existed).

## Production

Replace `example.com` throughout `.env.production.example` with a real domain
you control, and point its DNS (plus
`auth.<domain>`, `kuvert.<domain>`, `tafel.<domain>`, `zettel.<domain>`, and
`glocke.<domain>`, `schrank.<domain>`, and `herold.<domain>`) at this host -
see `.env.production.example` for a
filled-in starting point:

```sh
cp .env.production.example .env
# Replace example.com throughout and generate every secret independently
# before startup.
docker compose up -d --build
```

Caddy provisions HTTPS automatically via Let's Encrypt for each subdomain —
no certificate setup required. The local unknown-host redirect is
deliberately limited to `*.localhost`; an unknown host under the production
domain is denied during TLS setup and does not receive Caddy's internal
certificate.

### Environment variables

See `.env.example` — one file covers every variable needed by any of the
nine included app Compose files, since `include:` shares one Compose project
environment. The important one is `DOMAIN`; the rest are origin/CORS
allowlists and cross-service URLs that already default to the matching
`*.localhost` subdomain scheme. The included Glocke Compose service maps
`KUVERT_URL` and `TAFEL_URL` directly to its trusted notification-action
origins, so each app has one canonical public URL.

`GLOCKE_ALLOWED_ORIGINS` must contain the eight exact public frontend
origins: Schloss, Schlussel, Kuvert, Tafel, Zettel, Glocke, Schrank, and
Herold. `GLOCKE_URL` is the public HTTPS URL compiled into the Schloss,
Schlussel, Kuvert, Tafel, Zettel, Schrank, and Herold browser builds
(Wächter has no browser build of its own to compile it into). It must
be an HTTPS origin only, without credentials,
a path, query, or fragment. Do not set it to an internal Compose URL: producer
delivery uses `GLOCKE_BASE_URL`, while Schlussel export dispatch uses
`GLOCKE_EXPORT_URL`. Rebuild those frontend images after changing the public
URL.

Schlussel's six `*_EXPORT_URL` and six `*_DELETION_URL` values are a fixed,
deployment-owned registry. Keep them on `schloss-net` with their exact
`http://<service>:<port>/...` values from the examples. In particular,
Schrank and Herold export through `schrank-backend:3005/exports/me` and
`herold-backend:3006/exports/me`. Account-deletion consumers verify
Schlussel's short-lived service-scoped token using the internal JWKS URL and
the `schlussel` issuer; deploy all consumer migrations before deleting an
account. The examples also pin the dispatcher interval, lease, request
timeout, graceful-stop bound, attempt limit, and retry bounds; keep the fetch
timeout shorter than the lease when tuning them.

Wächter is split across `wachter` and `wachter-agent`. The API shares
`schloss-net` with Schloss and reaches the agent over the internal-only
`wachter-internal` network. Only the agent mounts the Docker socket, and both
containers require the same independently generated `WACHTER_AGENT_TOKEN`.
Tor's resolved Compose policy marks data-bearing, gateway, identity, and
monitoring containers `hof.wachter.critical=true`. Only stateless frontend
containers are `hof.wachter.restartable=true`, each with an explicit
`hof.wachter.critical=false`; the agent always treats critical as a denial.

### Enabling Browser Push

Both committed environment examples intentionally start with Browser Push
disabled and blank VAPID values. To opt in:

1. Generate one keypair with `npx web-push generate-vapid-keys` and store it
   in the deployment secret store. Do not regenerate it during deploys.
2. Set `GLOCKE_VAPID_SUBJECT` to a monitored `mailto:` or HTTPS contact,
   populate the generated public/private keys, and set
   `GLOCKE_BROWSER_PUSH_ENABLED=true`.
3. Set `GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS` to the smallest stable set of
   push providers actually needed. Exact entries match one host; a leading
   dot is an intentional suffix match, for example `.notify.windows.com`.
4. Recreate `glocke-backend`. The frontend obtains only the public key from
   its runtime status endpoint; no VAPID variable is a frontend build arg.

Keep a VAPID keypair stable for the life of existing subscriptions. Rotation
invalidates those subscriptions: deploy the replacement pair once, expect
clients to re-subscribe, and remove the old private key rather than retaining
multiple long-lived signing keys. Review the provider allowlist separately;
never add arbitrary domains to work around a rejected endpoint.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
