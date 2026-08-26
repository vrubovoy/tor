#!/bin/sh

set -eu

SERVICES='schloss schlussel-frontend kuvert-frontend tafel-frontend zettel-frontend glocke-frontend schrank-frontend herold-frontend'
TEST_TMPDIR=$(mktemp -d)
CONTAINER=

cleanup() {
	if [ -n "$CONTAINER" ]; then
		docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
	fi
	rm -rf "$TEST_TMPDIR"
}

trap cleanup EXIT INT TERM

wait_for_config() {
	attempt=0
	while [ "$attempt" -lt 40 ]; do
		if docker exec "$CONTAINER" wget -qO- http://127.0.0.1/config.js \
			>"$TEST_TMPDIR/config.js" 2>/dev/null; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 0.25
	done
	docker logs "$CONTAINER" >&2 || true
	return 1
}

run_and_check() {
	service=$1
	expected=$2
	shift 2
	image=$(docker compose config --format json | \
		jq -r --arg service "$service" \
		'.services[$service].image // ((.name // "tor") + "-" + $service)')
	if [ -z "$image" ] || ! docker image inspect "$image" >/dev/null 2>&1; then
		printf 'No built image found for %s\n' "$service" >&2
		return 1
	fi

	CONTAINER="tor-runtime-config-${service}-$$"
	docker run --detach --name "$CONTAINER" "$@" "$image" >/dev/null
	wait_for_config
	node test/validate-runtime-config.mjs "$TEST_TMPDIR/config.js" "$expected"
	docker exec "$CONTAINER" wget -qS -O /dev/null http://127.0.0.1/config.js \
		2>"$TEST_TMPDIR/headers"
	if ! tr -d '\r' <"$TEST_TMPDIR/headers" | \
		grep -qi '^  Cache-Control: no-store$'; then
		printf '%s /config.js is missing Cache-Control: no-store\n' "$service" >&2
		return 1
	fi
	docker rm --force "$CONTAINER" >/dev/null
	CONTAINER=
}

docker compose build $SERVICES

for service in $SERVICES; do
	case "$service" in
	schloss)
		run_and_check "$service" \
			'{"schlusselUrl":"https://auth.runtime.invalid","kuvertUrl":"https://kuvert.runtime.invalid"}' \
			-e SCHLUSSEL_WEB_URL=https://auth.runtime.invalid \
			-e KUVERT_URL=https://kuvert.runtime.invalid
		;;
	schlussel-frontend)
		run_and_check "$service" \
			'{"allowedReturnOrigins":["https://home.runtime.invalid","https://kuvert.runtime.invalid"],"defaultAppUrl":"https://home.runtime.invalid","glockeUrl":"https://glocke.runtime.invalid"}' \
			-e ALLOWED_RETURN_ORIGINS=https://home.runtime.invalid,https://kuvert.runtime.invalid \
			-e DEFAULT_APP_URL=https://home.runtime.invalid \
			-e GLOCKE_URL=https://glocke.runtime.invalid
		;;
	glocke-frontend)
		run_and_check "$service" \
			'{"schlusselUrl":"https://auth.runtime.invalid","schlossUrl":"https://home.runtime.invalid"}' \
			-e SCHLUSSEL_WEB_URL=https://auth.runtime.invalid \
			-e SCHLOSS_URL=https://home.runtime.invalid
		;;
	*)
		run_and_check "$service" \
			'{"schlusselUrl":"https://auth.runtime.invalid","schlossUrl":"https://home.runtime.invalid","glockeUrl":"https://glocke.runtime.invalid"}' \
			-e SCHLUSSEL_WEB_URL=https://auth.runtime.invalid \
			-e SCHLOSS_URL=https://home.runtime.invalid \
			-e GLOCKE_URL=https://glocke.runtime.invalid
		;;
	esac
done

# Prove that a second configuration changes Schloss without rebuilding it.
run_and_check schloss \
	'{"schlusselUrl":"https://auth.second.invalid","kuvertUrl":"https://kuvert.second.invalid"}' \
	-e SCHLUSSEL_WEB_URL=https://auth.second.invalid \
	-e KUVERT_URL=https://kuvert.second.invalid

printf 'Validated runtime configuration for all frontend images\n'
