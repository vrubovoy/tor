# Changelog

Brief log of notable changes, grouped by theme — not a full commit history
(see `git log` for that). New entries get appended under the section they
fit best; add a new section if none fits.

## Gateway
- Initial subdomain-routing Caddy gateway fronting schloss, schlussel, and
  kuvert behind a single host port, with `include:`-based one-command
  startup for the whole platform.
- Fixed `.env.example`'s origin defaults (`ALLOWED_ORIGINS`,
  `ALLOWED_RETURN_ORIGINS`, `DEFAULT_APP_URL`, `KUVERT_URL`,
  `SCHLUSSEL_WEB_URL`) from `http://` to `https://` - Caddy's automatic
  HTTPS upgrades every request here, so the old defaults failed the
  return_to allowlist for anyone copying this file as-is.
- Split `ALLOWED_ORIGINS` into `SCHLUSSEL_ALLOWED_ORIGINS` and
  `KUVERT_ALLOWED_ORIGINS` in `.env.example`/`.env.production.example` -
  one shared name fed the same value into both `schlussel` and
  `kuvert-backend`'s Compose files, silently overriding `kuvert-backend`'s
  own CORS allowlist.
  Requires schlussel#46 and kuvert#59's matching compose var renames.
- Added `SCHLOSS_URL` to `.env.example`/`.env.production.example` -
  kuvert's new header needs a URL to link back to schloss's home page,
  which no existing var covered (the others all point the other way).
- Fixed the TLS handshake failing outright (`SSL_ERROR_INTERNAL_ERROR_ALERT`
  in Firefox) on any subdomain that isn't one of the declared app sites
  (e.g. a typo'd `schlussel.localhost`) - Caddy only eagerly provisions
  certs for declared hostnames, so it had nothing to present for
  an unrecognized SNI and aborted the handshake before any HTTP routing
  could happen. Added a catch-all `*.{$DOMAIN}` site with `tls internal`
  (one wildcard cert, using the same local CA as the app sites) redirecting
  to the main site.
- Security audit finding: no response security headers were set anywhere
  (no HSTS, X-Content-Type-Options, Referrer-Policy, or frame-ancestors).
  Added a shared snippet with all four, imported by the app site
  blocks (not the catch-all, which only ever redirects).
- Removed the catch-all `*.{$DOMAIN}` site added above - its wildcard
  cert doesn't stay scoped to just its own traffic. Caddy serves it for
  app sites too whenever it's the best/only available match
  (e.g. right after their own exact-hostname certs expire, before
  renewal catches up), and real browsers reject a wildcard cert whose
  base domain is a single label with no dot (`*.localhost` has none) as
  a guard against overly-broad wildcards - so every real site
  intermittently failed TLS in an actual browser this way (`curl -k`
  doesn't enforce this check, which is how it went unnoticed). Back to
  a bare TLS alert for a typo'd/removed subdomain, a smaller problem
  than breaking every real one.
- Brought back a friendly redirect for a typo'd/removed subdomain,
  without the wildcard-cert risk above: a *hostless* catch-all site
  (`:443`, no host - unlike `*.{$DOMAIN}`, Caddy never folds this into
  app sites' automatic-HTTPS domain set) using on-demand TLS
  (one exact-hostname cert per subdomain, issued the first time it's
  actually requested, gated by an `ask` check so this can't become a
  certificate-issuance oracle for arbitrary hostnames). Every issued
  cert is an exact match, never a wildcard, so this can't collide with
  a real site's cert the way the original did.
- Added a narrow `frame-ancestors` exception for `auth.{$DOMAIN}/theme-sync.html`
  only (`https://{$DOMAIN}` and `https://kuvert.{$DOMAIN}`, not `'self'`,
  not `*`) - schlussel serves a small hub page there that schloss's and
  kuvert's frontends embed in a hidden iframe to keep the shared theme
  preference in sync across origins (their own localStorage can't be
  shared directly). Every other path on every site keeps the baseline
  `'none'`. Implemented as a separate `handle` block, not a matched
  `header` line alongside the unmatched baseline one - tried that first
  and Caddy silently didn't apply it in written order (confirmed in an
  isolated test container); mutually-exclusive `handle` blocks work
  correctly.
- Reverted the `frame-ancestors` exception above - the iframe hub it was
  for turned out to be fundamentally broken by Firefox/Safari storage
  partitioning and was replaced with a plain `fetch` API instead (no
  framing involved at all). `auth.{$DOMAIN}` is back to a single `handle`
  sending the baseline `'none'` uniformly, same as the other app sites.
  Also added kuvert's origin to `SCHLUSSEL_ALLOWED_ORIGINS`'s default -
  it now calls schlussel's `/theme` endpoint directly, cross-origin.
- Wired the new Tafel task-tracker service into the gateway: a
  `tafel.{$DOMAIN}` site block (same `security_headers` import as the
  existing app sites), `../tafel/docker-compose.yml` added to the
  `include:` list, and a new `TAFEL_ALLOWED_ORIGINS` var alongside
  updates to `SCHLUSSEL_ALLOWED_ORIGINS`/`ALLOWED_RETURN_ORIGINS` to
  include Tafel's frontend origin (same reasoning as kuvert's own entry
  above - `ThemeSync` and the PKCE login flow both need it).
- Wired the new Zettel note-taking app into the gateway: added its
  `zettel.{$DOMAIN}` route, Compose include, CI checkout, and shared
  environment variables, bringing the gateway to five app sites.
- Updated all five reverse-proxy targets to their current Compose service
  names: `schloss`, `schlussel-frontend`, `kuvert-frontend`,
  `tafel-frontend`, and `zettel-frontend`. The backend Compose services
  (`schlussel`, `kuvert-backend`, `tafel-backend`, and `zettel-backend`)
  remain internal and are not gateway targets.
- Restricted unknown-host internal TLS to `*.localhost`. Unknown local app
  hosts receive an exact internal-CA certificate and a `302` redirect to
  `https://localhost` with the path and query preserved. Unknown production
  hosts are denied certificate issuance, receive no Caddy internal-CA
  certificate, and fail the TLS handshake before any HTTP response.
- Wired Glocke's notification foundation into the gateway: added the
  `glocke.{$DOMAIN}` route, sibling Compose include, CI checkout and image
  build checks, explicit route coverage, and local/production environment
  examples. Tor now fronts six app sites.
- Completed Glocke's production producer configuration with four independently
  pinned producer credentials plus its separate Schlüssel lookup credential.
  The included Compose project maps the existing Kuvert/Tafel launcher URLs
  directly to Glocke's trusted action origins, and CI validates both fully
  resolved example environments and their directional credential mappings
  without real secrets.

## Docs
- Repo slug renamed to lowercase for consistency with the other Hof
  projects - the project name is now written lowercase everywhere,
  including at the start of sentences.
- License/CI badges, a link to the Hof meta-repo, `.env.production.example`
  for real-domain deployment, and a missing `.gitignore` for `.env`.
- Fixed remaining prose mentions of the project name to lowercase "tor"
  throughout README.md and CONTRIBUTING.md, including at sentence starts.
- Added CODE_OF_CONDUCT.md, SECURITY.md, issue templates, and a pull
  request template.
- Documented the one-time step of trusting Caddy's local HTTPS CA in the
  browser for local dev (`*.localhost` can't get a real Let's Encrypt cert),
  including how to re-trust it if `caddy-data` ever gets wiped and the CA
  regenerates with a new key (previously undocumented, discovered when a
  wiped volume produced a `SEC_ERROR_BAD_SIGNATURE` instead of the usual
  unknown-issuer warning). Fixed the README's example URLs from `http://` to
  `https://` to match Caddy's actual automatic upgrade behavior.
