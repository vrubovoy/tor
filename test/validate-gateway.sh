#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CADDY_IMAGE=${CADDY_IMAGE:-caddy:2-alpine}
CONTAINER=
FAILURES=0
TEST_TMPDIR=$(mktemp -d)

stop_caddy() {
	if [ -n "$CONTAINER" ]; then
		docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
		CONTAINER=
	fi
}

cleanup() {
	stop_caddy
	rm -rf "$TEST_TMPDIR"
}

trap cleanup EXIT INT TERM

start_caddy() {
	domain=$1
	CONTAINER="tor-caddy-test-$$"

	if ! docker run --detach --rm --network none \
		--name "$CONTAINER" \
		--env "DOMAIN=$domain" \
		--volume "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
		"$CADDY_IMAGE" caddy run \
		--config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
		printf 'Could not start Caddy for DOMAIN=%s\n' "$domain" >&2
		return 1
	fi

	attempt=0
	while [ "$attempt" -lt 40 ]; do
		if docker exec "$CONTAINER" curl --silent --fail \
			http://127.0.0.1:2019/config/ >/dev/null 2>&1; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 0.25
	done

	printf 'Caddy did not become ready for DOMAIN=%s\n' "$domain" >&2
	docker logs "$CONTAINER" >&2 || true
	return 1
}

test_upstreams() {
	caddy_config="$TEST_TMPDIR/caddy.json"
	compose_config="$TEST_TMPDIR/compose.json"

	if ! docker run --rm --network none \
		--env DOMAIN=localhost \
		--volume "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
		"$CADDY_IMAGE" caddy adapt \
		--config /etc/caddy/Caddyfile --adapter caddyfile >"$caddy_config"; then
		return 1
	fi
	# This checks the Caddyfile's static hostname-to-upstream mapping, not
	# which containers happen to be running - activate every optional
	# profile so the comparison covers every app the Caddyfile routes to,
	# the same set validate-compose.sh already exercises.
	if ! docker compose --project-directory "$ROOT" \
		--env-file "$ROOT/.env.example" \
		--file "$ROOT/docker-compose.yml" \
		--profile kuvert --profile tafel --profile zettel --profile glocke \
		--profile schrank --profile herold --profile wachter \
		config --format json \
		>"$compose_config"; then
		return 1
	fi

	# Compare only public web routes. The three *-backend services and the
	# schlussel API service are internal dependencies, not gateway targets.
	actual=$(jq -r '
		[
			.apps.http.servers[].routes[]?
			| select(.match[0].host? | length == 1)
			| .match[0].host[0] as $host
			| [
				.handle[]?
				| ..
				| objects
				| select(.handler? == "reverse_proxy")
				| .upstreams[]?.dial
			][0] as $upstream
			| select($upstream != null)
			| "\($host) \($upstream)"
		]
		| sort
		| .[]
	' "$caddy_config")

	expected=$(jq -r '
		.services
		| keys
		| map(select(. == "schloss" or endswith("-frontend")))
		| map(
			. as $service
			| if $service == "schloss" then
				"localhost \($service):80"
			elif $service == "schlussel-frontend" then
				"auth.localhost \($service):80"
			else
				"\($service | rtrimstr("-frontend")).localhost \($service):80"
			end
		)
		| sort
		| .[]
	' "$compose_config")

	if [ "$actual" != "$expected" ]; then
		printf 'Unexpected app upstreams.\nExpected:\n%s\nActual:\n%s\n' \
			"$expected" "$actual" >&2
		return 1
	fi

	case "$actual" in
	*'glocke.localhost glocke-frontend:80'*) ;;
	*)
		printf 'Glocke gateway route is missing from the adapted Caddy configuration.\n' >&2
		return 1
		;;
	esac
}

adapt_caddyfile() {
	# Static config-only check: adapts the Caddyfile the same way
	# test_upstreams already does (no running upstream, --network none) - it
	# does not start Caddy or send it any request. That mirrors this
	# script's existing static/no-running-stack idiom for anything that can
	# be answered from config alone.
	#
	# What this CANNOT verify statically: the actual live HTTP response for
	# /sw.js (real 404 vs the SPA's index.html fallback, and the MIME
	# type/Cache-Control glocke-frontend itself ends up sending) - that
	# depends on glocke-frontend's own static file server, which isn't
	# running in this test. Per the Browser Push spec (issue #49), that
	# live verification happens manually during the Compose-upgrade step in
	# the rollout, not in CI.
	out=$1
	docker run --rm --network none \
		--env DOMAIN=localhost \
		--volume "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
		"$CADDY_IMAGE" caddy adapt \
		--config /etc/caddy/Caddyfile --adapter caddyfile >"$out"
}

test_sw_js_route_headers() {
	adapted="$TEST_TMPDIR/sw-adapted.json"
	if ! adapt_caddyfile "$adapted"; then
		return 1
	fi

	# The header rewrite lives inside a `reverse_proxy` handler's own
	# `header_down` config (`.headers.response.set`), not a standalone
	# `headers` handler (`.response.set`) - `header_down` is the Caddy
	# construct that actually replaces an upstream's already-set response
	# header rather than appending a second value alongside it (reverse_proxy
	# copies every upstream header via Add, so a plain `header` directive set
	# beforehand ends up duplicated instead of replaced). Recurse into every
	# descendant object with a "set" key so either shape matches.
	jq -e '
	  [
	    .apps.http.servers[].routes[]
	    | select(.match[0].host[0]? == "glocke.localhost")
	    | ..
	    | objects
	    | select(.match? and .handle?)
	    | select(.match[]?.path[]? // "" | test("(?i)/sw\\.js$"))
	  ] as $sw_routes
	  | ($sw_routes | length > 0)
	  and ([
	    $sw_routes[]
	    | ..
	    | objects
	    | select(has("set"))
	    | .set["Cache-Control"][]?
	    | select(test("(?i)no-cache"))
	  ] | length > 0)
	  and ([
	    $sw_routes[]
	    | ..
	    | objects
	    | select(has("set"))
	    | .set["Content-Type"][]?
	    | select(test("(?i)javascript"))
	  ] | length > 0)
	' "$adapted" >/dev/null
}

test_schloss_wachter_proxy() {
	adapted="$TEST_TMPDIR/schloss-adapted.json"
	if ! docker run --rm --network none \
		--volume "$ROOT/../schloss/Caddyfile:/etc/caddy/Caddyfile:ro" \
		"$CADDY_IMAGE" caddy adapt \
		--config /etc/caddy/Caddyfile --adapter caddyfile >"$adapted"; then
		return 1
	fi

	# Schloss is the only browser entrypoint for Wächter. The prefix must be
	# stripped exactly once before forwarding to the API's current service and
	# port; a plain reverse_proxy would send paths Wächter does not expose.
	jq -e '
	  [
	    .apps.http.servers[].routes[]
	    | select(.match[]?.path[]? == "/wachter/*")
	  ] as $routes
	  | ($routes | length == 1)
	  and ([$routes[] | .. | objects
	    | select(.handler? == "rewrite")
	    | .strip_path_prefix] == ["/wachter"])
	  and ([$routes[] | .. | objects
	    | select(.handler? == "reverse_proxy")
	    | .upstreams[]?.dial] == ["wachter:3007"])
	' "$adapted" >/dev/null
}

test_no_manifest_route() {
	# iOS/PWA install is explicitly out of scope for this phase (see the
	# Browser Push spec). This guards against accidentally shipping a
	# manifest route/header alongside /sw.js before that phase is designed
	# - a regression guard, not expected to ever go red on its own.
	adapted="$TEST_TMPDIR/manifest-adapted.json"
	if ! adapt_caddyfile "$adapted"; then
		return 1
	fi

	if grep -qi 'manifest' "$ROOT/Caddyfile"; then
		printf 'Caddyfile mentions "manifest" - iOS/PWA installability is out of scope for this phase\n' >&2
		return 1
	fi

	jq -e '
	  [
	    .apps.http.servers[].routes[]
	    | select(.match[0].host[0]? == "glocke.localhost")
	    | ..
	    | objects
	    | select(.match? and .handle?)
	    | select(.match[]?.path[]? // "" | test("(?i)manifest"))
	  ] | length == 0
	' "$adapted" >/dev/null
}

test_local_unknown_host() {
	if ! start_caddy localhost; then
		stop_caddy
		return 1
	fi

	# Local typos deliberately get an exact (never wildcard) certificate from
	# Caddy's local CA, followed by a redirect that preserves path and query.
	if output=$(docker exec "$CONTAINER" curl \
		--silent --show-error \
		--connect-timeout 5 --max-time 10 \
		--output /dev/null --write-out '%{http_code} %{redirect_url}' \
		--cacert /data/caddy/pki/authorities/local/root.crt \
		--resolve typo.localhost:443:127.0.0.1 \
		'https://typo.localhost/check?source=test' 2>&1); then
		status=0
	else
		status=$?
	fi

	if [ "$status" -ne 0 ] || \
		[ "$output" != '302 https://localhost/check?source=test' ]; then
		stop_caddy
		printf 'Unknown local host did not verify and redirect to localhost: %s\n' \
			"$output" >&2
		return 1
	fi

	leaf_cert="$TEST_TMPDIR/typo.localhost.crt"
	intermediate_cert="$TEST_TMPDIR/caddy-intermediate.crt"
	root_cert="$TEST_TMPDIR/caddy-root.crt"
	if ! docker cp \
		"$CONTAINER:/data/caddy/certificates/local/typo.localhost/typo.localhost.crt" \
		"$leaf_cert" >/dev/null || \
		! docker cp \
		"$CONTAINER:/data/caddy/pki/authorities/local/intermediate.crt" \
		"$intermediate_cert" >/dev/null || \
		! docker cp \
		"$CONTAINER:/data/caddy/pki/authorities/local/root.crt" \
		"$root_cert" >/dev/null; then
		stop_caddy
		printf '%s\n' 'Could not inspect the unknown local host certificate' >&2
		return 1
	fi
	stop_caddy

	if ! san=$(openssl x509 -in "$leaf_cert" -noout \
		-ext subjectAltName 2>&1); then
		printf 'Could not read the unknown local host certificate SAN: %s\n' \
			"$san" >&2
		return 1
	fi
	case "$san" in
	*'DNS:typo.localhost'*) ;;
	*)
		printf 'Unknown local host certificate has an unexpected SAN: %s\n' \
			"$san" >&2
		return 1
		;;
	esac

	issuer=$(openssl x509 -in "$leaf_cert" -noout -issuer -nameopt RFC2253)
	ca_subject=$(openssl x509 -in "$intermediate_cert" -noout \
		-subject -nameopt RFC2253)
	issuer=${issuer#issuer=}
	ca_subject=${ca_subject#subject=}
	if [ "$issuer" != "$ca_subject" ]; then
		printf 'Unknown local host certificate issuer is not Caddy CA.\nIssuer: %s\nCaddy CA: %s\n' \
			"$issuer" "$ca_subject" >&2
		return 1
	fi

	if ! verify_output=$(openssl verify -CAfile "$root_cert" \
		-untrusted "$intermediate_cert" -verify_hostname typo.localhost \
		"$leaf_cert" 2>&1); then
		printf 'Unknown local host certificate did not verify against Caddy CA: %s\n' \
			"$verify_output" >&2
		return 1
	fi
}

test_production_unknown_host() {
	if ! start_caddy example.test; then
		stop_caddy
		return 1
	fi

	# The ask policy denies non-local names. The expected result is a TLS alert,
	# not an internal certificate followed by an HTTP redirect or 421 response.
	if output=$(docker exec "$CONTAINER" curl \
		--insecure --verbose \
		--connect-timeout 5 --max-time 10 \
		--output /dev/null \
		--resolve typo.example.test:443:127.0.0.1 \
		'https://typo.example.test/' 2>&1); then
		status=0
	else
		status=$?
	fi
	stop_caddy

	if [ "$status" -ne 35 ]; then
		printf 'Unknown production host did not fail during TLS setup (curl status %s): %s\n' \
			"$status" "$output" >&2
		return 1
	fi
	case "$output" in
	*'alert internal error'*) ;;
	*)
		printf 'Unknown production host had an unexpected TLS failure: %s\n' \
			"$output" >&2
		return 1
		;;
	esac
}

run_test() {
	name=$1
	test_function=$2

	if "$test_function"; then
		printf 'ok - %s\n' "$name"
	else
		printf 'not ok - %s\n' "$name" >&2
		FAILURES=$((FAILURES + 1))
	fi
}

run_test 'all app hosts use current Compose service upstreams' test_upstreams
run_test '/sw.js gets a real-JS Content-Type and Cache-Control: no-cache' test_sw_js_route_headers
run_test 'Schloss strips /wachter and proxies exactly to wachter:3007' test_schloss_wachter_proxy
run_test 'no manifest.json/webmanifest route exists yet (iOS/PWA out of scope)' test_no_manifest_route
run_test 'unknown *.localhost hosts redirect locally' test_local_unknown_host
run_test 'unknown production hosts do not receive internal certificates' test_production_unknown_host

if [ "$FAILURES" -ne 0 ]; then
	printf '%s gateway validation(s) failed\n' "$FAILURES" >&2
	exit 1
fi
