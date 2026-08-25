#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GLOCKE_ROOT=$(CDPATH= cd -- "$ROOT/../glocke" && pwd)
NETWORK="tor-sw-test-$$"
FRONTEND="tor-glocke-sw-test-$$"
GATEWAY="tor-gateway-sw-test-$$"
TEST_TMPDIR=$(mktemp -d)

cleanup() {
	docker rm --force "$GATEWAY" "$FRONTEND" >/dev/null 2>&1 || true
	docker network rm "$NETWORK" >/dev/null 2>&1 || true
	rm -rf "$TEST_TMPDIR"
}

trap cleanup EXIT INT TERM

if [ "${SKIP_BUILD:-}" != 1 ]; then
	docker compose --env-file "$ROOT/.env.example" build glocke-frontend
fi

PROJECT=$(docker compose --env-file "$ROOT/.env.example" config --format json \
	| jq -r .name)
set -- $(docker image ls --quiet \
	--filter "label=com.docker.compose.project=$PROJECT" \
	--filter label=com.docker.compose.service=glocke-frontend)
IMAGE=${1:-}
if [ -z "$IMAGE" ]; then
	printf 'No built glocke-frontend image is available\n' >&2
	exit 1
fi

docker network create "$NETWORK" >/dev/null
docker run --detach --rm --name "$FRONTEND" --network "$NETWORK" \
	--network-alias glocke-frontend "$IMAGE" >/dev/null
docker run --detach --rm --name "$GATEWAY" --network "$NETWORK" \
	--network-alias glocke.localhost --env DOMAIN=localhost \
	--volume "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
	caddy:2-alpine caddy run --config /etc/caddy/Caddyfile \
	--adapter caddyfile >/dev/null

attempt=0
while [ "$attempt" -lt 40 ]; do
	if docker exec "$GATEWAY" curl --insecure --silent --fail \
		--output /dev/null https://glocke.localhost/sw.js; then
		break
	fi
	attempt=$((attempt + 1))
	sleep 0.25
done
if [ "$attempt" -eq 40 ]; then
	printf 'Built Glocke frontend did not become reachable through the gateway\n' >&2
	docker logs "$FRONTEND" >&2 || true
	docker logs "$GATEWAY" >&2 || true
	exit 1
fi

docker exec "$GATEWAY" curl --insecure --silent --show-error \
	--dump-header - --output /dev/null https://glocke.localhost/sw.js \
	| tr -d '\r' >"$TEST_TMPDIR/headers"
docker exec "$GATEWAY" curl --insecure --silent --show-error --fail \
	https://glocke.localhost/sw.js >"$TEST_TMPDIR/sw.js"

assert_single_header() {
	name=$1
	expected=$2
	count=$(awk -F ': ' -v name="$name" \
		'tolower($1) == tolower(name) { count++ } END { print count + 0 }' \
		"$TEST_TMPDIR/headers")
	value=$(awk -F ': ' -v name="$name" \
		'tolower($1) == tolower(name) { print $2 }' \
		"$TEST_TMPDIR/headers")
	if [ "$count" -ne 1 ] || [ "$value" != "$expected" ]; then
		printf 'Expected one %s: %s header, got %s value(s): %s\n' \
			"$name" "$expected" "$count" "$value" >&2
		return 1
	fi
}

if ! awk '$1 ~ /^HTTP\// && $2 == 200 { found = 1 } END { exit !found }' \
	"$TEST_TMPDIR/headers"; then
	printf '/sw.js did not return HTTP 200\n' >&2
	exit 1
fi
assert_single_header Content-Type 'application/javascript; charset=utf-8'
assert_single_header Cache-Control no-cache
assert_single_header X-Content-Type-Options nosniff

if ! cmp -s "$GLOCKE_ROOT/frontend/public/sw.js" "$TEST_TMPDIR/sw.js"; then
	printf '/sw.js body differs from Glocke frontend/public/sw.js\n' >&2
	exit 1
fi

printf 'Validated built /sw.js body and gateway headers\n'
