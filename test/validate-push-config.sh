#!/bin/sh

# Browser Push delivery (issue #49) - checks that don't fit
# validate-compose.sh's single "does this exact example file work"
# contract:
#   - a synthetic enabled-mode env (flag true, all VAPID vars set) reaches
#     glocke-backend and never leaks into any frontend's build args
#   - a synthetic disabled-mode env (flag false, VAPID vars blank) still
#     produces a valid Compose config - same graceful-noop contract already
#     relied on for the producer HMAC vars today
#   - the CI workflow's own env: block carries a fixed, non-empty,
#     CI-only VAPID keypair, not the example placeholder text
#
# Follows validate-gateway.sh's run_test/tally convention since, like that
# script and unlike validate-compose.sh, this file checks several
# independent things in one run.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BASE_ENV="$ROOT/.env.example"
WORKFLOW="$ROOT/.github/workflows/test.yml"
FAILURES=0
TEST_TMPDIR=$(mktemp -d)

trap 'rm -rf "$TEST_TMPDIR"' EXIT INT TERM

# Starts from the committed .env.example, drops any existing lines for the
# five Browser Push vars (so this stays correct once they're added there
# too), and appends the values passed in "$@" as literal NAME=VALUE lines.
make_variant() {
	out=$1
	shift
	grep -v -E '^(GLOCKE_BROWSER_PUSH_ENABLED|GLOCKE_VAPID_SUBJECT|GLOCKE_VAPID_PUBLIC_KEY|GLOCKE_VAPID_PRIVATE_KEY|GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS)=' \
		"$BASE_ENV" >"$out"
	for line in "$@"; do
		printf '%s\n' "$line" >>"$out"
	done
}

test_enabled_mode() {
	variant="$TEST_TMPDIR/enabled.env"
	config="$TEST_TMPDIR/enabled.json"
	make_variant "$variant" \
		'GLOCKE_BROWSER_PUSH_ENABLED=true' \
		'GLOCKE_VAPID_SUBJECT=mailto:push-test@example.invalid' \
		'GLOCKE_VAPID_PUBLIC_KEY=test-fixture-vapid-public-key' \
		'GLOCKE_VAPID_PRIVATE_KEY=test-fixture-vapid-private-key' \
		'GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS=fcm.googleapis.com,updates.push.services.mozilla.com,web.push.apple.com'

	if ! docker compose --env-file "$variant" config --quiet; then
		printf 'docker compose config --quiet failed for the enabled-mode fixture\n' >&2
		return 1
	fi
	docker compose --env-file "$variant" config --format json >"$config"

	if ! jq -e '
	  .services as $services
	  | $services."glocke-backend".environment.GLOCKE_BROWSER_PUSH_ENABLED == "true"
	  and $services."glocke-backend".environment.GLOCKE_VAPID_SUBJECT == "mailto:push-test@example.invalid"
	  and $services."glocke-backend".environment.GLOCKE_VAPID_PUBLIC_KEY == "test-fixture-vapid-public-key"
	  and $services."glocke-backend".environment.GLOCKE_VAPID_PRIVATE_KEY == "test-fixture-vapid-private-key"
	  and $services."glocke-backend".environment.GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS == "fcm.googleapis.com,updates.push.services.mozilla.com,web.push.apple.com"
	  and ([
	    $services[]
	    | select(.build.args? != null)
	    | .build.args
	    | to_entries[]
	    | select(
	        (.value == "test-fixture-vapid-private-key")
	        or (.value == "test-fixture-vapid-public-key")
	        or (.key | test("VAPID"))
	      )
	  ] | length == 0)
	' "$config" >/dev/null; then
		printf 'glocke-backend environment does not carry the enabled-mode Browser Push vars, or they leaked into a frontend build args block\n' >&2
		return 1
	fi
}

test_disabled_mode() {
	variant="$TEST_TMPDIR/disabled.env"
	config="$TEST_TMPDIR/disabled.json"
	make_variant "$variant" \
		'GLOCKE_BROWSER_PUSH_ENABLED=false' \
		'GLOCKE_VAPID_SUBJECT=' \
		'GLOCKE_VAPID_PUBLIC_KEY=' \
		'GLOCKE_VAPID_PRIVATE_KEY=' \
		'GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS='

	if ! docker compose --env-file "$variant" config --quiet; then
		printf 'docker compose config --quiet failed for the disabled-mode fixture (flag false, VAPID vars blank should still validate)\n' >&2
		return 1
	fi
	docker compose --env-file "$variant" config --format json >"$config"

	if ! jq -e '
	  .services as $services
	  | $services."glocke-backend".environment.GLOCKE_BROWSER_PUSH_ENABLED == "false"
	  and $services."glocke-backend".environment.GLOCKE_VAPID_SUBJECT == ""
	  and $services."glocke-backend".environment.GLOCKE_VAPID_PUBLIC_KEY == ""
	  and $services."glocke-backend".environment.GLOCKE_VAPID_PRIVATE_KEY == ""
	  and $services."glocke-backend".environment.GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS == ""
	' "$config" >/dev/null; then
		printf 'glocke-backend environment does not reflect the disabled-mode Browser Push vars (flag false, blank VAPID vars)\n' >&2
		return 1
	fi
}

# Reads the literal value assigned to $1 inside the workflow's top-level
# `env:` block (steps may declare their own `env:` blocks too; this only
# looks at the job-level one, same block the existing HMAC secrets live in).
workflow_env_value() {
	name=$1
	awk -v name="$name" '
	  /^    env:/ { in_env = 1; next }
	  in_env && /^    [A-Za-z]/ { in_env = 0 }
	  in_env {
	    line = $0
	    sub(/^ +/, "", line)
	    if (index(line, name ":") == 1) {
	      sub("^" name ": *", "", line)
	      print line
	      exit
	    }
	  }
	' "$WORKFLOW"
}

test_ci_workflow_keypair() {
	public=$(workflow_env_value GLOCKE_VAPID_PUBLIC_KEY)
	private=$(workflow_env_value GLOCKE_VAPID_PRIVATE_KEY)
	subject=$(workflow_env_value GLOCKE_VAPID_SUBJECT)

	if [ -z "$public" ] || [ -z "$private" ] || [ -z "$subject" ]; then
		printf 'CI workflow env: block is missing GLOCKE_VAPID_PUBLIC_KEY, GLOCKE_VAPID_PRIVATE_KEY, or GLOCKE_VAPID_SUBJECT (%s)\n' "$WORKFLOW" >&2
		return 1
	fi

	# Must be a fixed pair generated for CI, not a copy-paste of either
	# example file's obvious placeholder text. Checked line-by-line (not as
	# one blob) since each example file has separate public/private lines.
	for example in "$ROOT/.env.example" "$ROOT/.env.production.example"; do
		[ -f "$example" ] || continue
		if grep -E '^GLOCKE_VAPID_(PUBLIC|PRIVATE)_KEY=' "$example" | cut -d= -f2- |
			grep -Fxq -e "$public" -e "$private"; then
			printf 'CI workflow VAPID key matches the placeholder text in %s verbatim - CI needs its own fixed keypair, not the example placeholder\n' "$example" >&2
			return 1
		fi
	done

	if [ "$public" = "$private" ]; then
		printf 'CI workflow GLOCKE_VAPID_PUBLIC_KEY and GLOCKE_VAPID_PRIVATE_KEY must not be equal\n' >&2
		return 1
	fi

	# Real VAPID keys are urlsafe-base64 (RFC 4648 sec 5, no padding) - not a
	# strict crypto check, just enough to catch "TODO"/empty-ish placeholder
	# text standing in for a real generated key.
	case "$public" in
	*[!A-Za-z0-9_-]*)
		printf 'CI GLOCKE_VAPID_PUBLIC_KEY does not look like a base64url-encoded key: %s\n' "$public" >&2
		return 1
		;;
	esac
	case "$private" in
	*[!A-Za-z0-9_-]*)
		printf 'CI GLOCKE_VAPID_PRIVATE_KEY does not look like a base64url-encoded key: %s\n' "$private" >&2
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

run_test 'enabled-mode Browser Push config reaches glocke-backend and never leaks into frontend build args' test_enabled_mode
run_test 'disabled-mode Browser Push config (flag false, VAPID vars blank) still validates' test_disabled_mode
run_test 'CI workflow env: block carries a fixed, non-empty, CI-only VAPID keypair' test_ci_workflow_keypair

if [ "$FAILURES" -ne 0 ]; then
	printf '%s Browser Push config validation(s) failed\n' "$FAILURES" >&2
	exit 1
fi
