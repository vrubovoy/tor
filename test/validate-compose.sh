#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
	printf 'Usage: %s ENV_FILE\n' "$0" >&2
	exit 2
fi

ENV_FILE=$1
CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT INT TERM

# Validate the selected example itself even when CI supplies credentials for
# other Compose-based tests in the same job.
unset SCHLUSSEL_TO_GLOCKE_HMAC_SECRET
unset GLOCKE_TO_SCHLUSSEL_HMAC_SECRET
unset KUVERT_TO_GLOCKE_HMAC_SECRET
unset TAFEL_TO_GLOCKE_HMAC_SECRET
unset ZETTEL_TO_GLOCKE_HMAC_SECRET
unset GLOCKE_URL
unset GLOCKE_BROWSER_PUSH_ENABLED
unset GLOCKE_VAPID_SUBJECT
unset GLOCKE_VAPID_PUBLIC_KEY
unset GLOCKE_VAPID_PRIVATE_KEY
unset GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS

GLOCKE_URL=
GLOCKE_BROWSER_PUSH_ENABLED=
GLOCKE_VAPID_SUBJECT=
GLOCKE_VAPID_PUBLIC_KEY=
GLOCKE_VAPID_PRIVATE_KEY=
GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS=
while IFS='=' read -r name value; do
	case "$name" in
	GLOCKE_URL) GLOCKE_URL=$value ;;
	GLOCKE_BROWSER_PUSH_ENABLED) GLOCKE_BROWSER_PUSH_ENABLED=$value ;;
	GLOCKE_VAPID_SUBJECT) GLOCKE_VAPID_SUBJECT=$value ;;
	GLOCKE_VAPID_PUBLIC_KEY) GLOCKE_VAPID_PUBLIC_KEY=$value ;;
	GLOCKE_VAPID_PRIVATE_KEY) GLOCKE_VAPID_PRIVATE_KEY=$value ;;
	GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS) GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS=$value ;;
	esac
done <"$ENV_FILE"

if [ -z "$GLOCKE_URL" ]; then
	printf 'GLOCKE_URL is missing from %s\n' "$ENV_FILE" >&2
	exit 1
fi

# Browser Push (issue #49): both example env files must carry the VAPID
# keypair/subject, the feature flag, and the provider allowlist so
# glocke-backend can be started from either example as-is. Blank values are a
# valid *disabled* runtime state (see validate-push-config.sh), but the
# committed examples themselves are expected to show the working, enabled
# shape - same convention as the HMAC secret placeholders above.
if [ -z "$GLOCKE_BROWSER_PUSH_ENABLED" ] || [ -z "$GLOCKE_VAPID_SUBJECT" ] ||
	[ -z "$GLOCKE_VAPID_PUBLIC_KEY" ] || [ -z "$GLOCKE_VAPID_PRIVATE_KEY" ] ||
	[ -z "$GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS" ]; then
	printf 'One or more Browser Push vars (GLOCKE_BROWSER_PUSH_ENABLED, GLOCKE_VAPID_SUBJECT, GLOCKE_VAPID_PUBLIC_KEY, GLOCKE_VAPID_PRIVATE_KEY, GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS) are missing from %s\n' "$ENV_FILE" >&2
	exit 1
fi

node "$(dirname "$0")/validate-public-origin.mjs" "$GLOCKE_URL"

if ! docker compose --env-file "$ENV_FILE" config --quiet; then
	printf 'docker compose config --quiet failed for %s\n' "$ENV_FILE" >&2
	exit 1
fi

docker compose --env-file "$ENV_FILE" config --format json >"$CONFIG"

jq -e --arg glocke_url "$GLOCKE_URL" \
  --arg vapid_enabled "$GLOCKE_BROWSER_PUSH_ENABLED" \
  --arg vapid_subject "$GLOCKE_VAPID_SUBJECT" \
  --arg vapid_public "$GLOCKE_VAPID_PUBLIC_KEY" \
  --arg vapid_private "$GLOCKE_VAPID_PRIVATE_KEY" \
  --arg vapid_hosts "$GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS" '
  .services as $services
  | [
      $services.schlussel.environment.SCHLUSSEL_TO_GLOCKE_HMAC_SECRET,
      $services."kuvert-backend".environment.KUVERT_TO_GLOCKE_HMAC_SECRET,
      $services."tafel-backend".environment.TAFEL_TO_GLOCKE_HMAC_SECRET,
      $services."zettel-backend".environment.ZETTEL_TO_GLOCKE_HMAC_SECRET,
      $services."glocke-backend".environment.GLOCKE_TO_SCHLUSSEL_HMAC_SECRET
    ] as $secrets
  | ($secrets | all(type == "string" and length >= 32))
  and (($secrets | unique | length) == 5)
  and ($services."glocke-backend".environment.GLOCKE_EVENT_SOURCES == "schlussel,kuvert,tafel,zettel")
  and ([
    $services.schlussel.environment.SCHLUSSEL_TO_GLOCKE_HMAC_KEY_ID,
    $services."kuvert-backend".environment.KUVERT_TO_GLOCKE_HMAC_KEY_ID,
    $services."tafel-backend".environment.TAFEL_TO_GLOCKE_HMAC_KEY_ID,
    $services."zettel-backend".environment.ZETTEL_TO_GLOCKE_HMAC_KEY_ID,
    $services."glocke-backend".environment.GLOCKE_TO_SCHLUSSEL_HMAC_KEY_ID
  ] == ["schlussel-v1", "kuvert-v1", "tafel-v1", "zettel-v1", "glocke-v1"])
  and ([
    $services.schlussel.environment.GLOCKE_BASE_URL,
    $services."kuvert-backend".environment.GLOCKE_BASE_URL,
    $services."tafel-backend".environment.GLOCKE_BASE_URL,
    $services."zettel-backend".environment.GLOCKE_BASE_URL
  ] | all(. == "http://glocke-backend:3004"))
  and ($services.schlussel.environment.SCHLUSSEL_TO_GLOCKE_HMAC_KEY_ID == $services."glocke-backend".environment.GLOCKE_SOURCE_KEY_ID_SCHLUSSEL)
  and ($services.schlussel.environment.SCHLUSSEL_TO_GLOCKE_HMAC_SECRET == $services."glocke-backend".environment.GLOCKE_SOURCE_SECRET_SCHLUSSEL)
  and ($services."kuvert-backend".environment.KUVERT_TO_GLOCKE_HMAC_KEY_ID == $services."glocke-backend".environment.GLOCKE_SOURCE_KEY_ID_KUVERT)
  and ($services."kuvert-backend".environment.KUVERT_TO_GLOCKE_HMAC_SECRET == $services."glocke-backend".environment.GLOCKE_SOURCE_SECRET_KUVERT)
  and ($services."tafel-backend".environment.TAFEL_TO_GLOCKE_HMAC_KEY_ID == $services."glocke-backend".environment.GLOCKE_SOURCE_KEY_ID_TAFEL)
  and ($services."tafel-backend".environment.TAFEL_TO_GLOCKE_HMAC_SECRET == $services."glocke-backend".environment.GLOCKE_SOURCE_SECRET_TAFEL)
  and ($services."zettel-backend".environment.ZETTEL_TO_GLOCKE_HMAC_KEY_ID == $services."glocke-backend".environment.GLOCKE_SOURCE_KEY_ID_ZETTEL)
  and ($services."zettel-backend".environment.ZETTEL_TO_GLOCKE_HMAC_SECRET == $services."glocke-backend".environment.GLOCKE_SOURCE_SECRET_ZETTEL)
  and ($services.schlussel.environment.GLOCKE_TO_SCHLUSSEL_HMAC_KEY_ID == $services."glocke-backend".environment.GLOCKE_TO_SCHLUSSEL_HMAC_KEY_ID)
  and ($services.schlussel.environment.GLOCKE_TO_SCHLUSSEL_HMAC_SECRET == $services."glocke-backend".environment.GLOCKE_TO_SCHLUSSEL_HMAC_SECRET)
  and ($services."glocke-backend".environment.ALLOWED_ORIGINS == ([
    $services."glocke-frontend".build.args.VITE_SCHLOSS_URL,
    $services."glocke-frontend".build.args.VITE_SCHLUSSEL_URL,
    $services.schloss.build.args.VITE_KUVERT_URL,
    $services.schloss.build.args.VITE_TAFEL_URL,
    $services.schloss.build.args.VITE_ZETTEL_URL,
    $services.schloss.build.args.VITE_GLOCKE_URL,
    $services.schloss.build.args.VITE_SCHRANK_URL
  ] | join(",")))
  and ([
    $services.schloss.build.args.VITE_GLOCKE_URL,
    $services."schlussel-frontend".build.args.VITE_GLOCKE_URL,
    $services."kuvert-frontend".build.args.VITE_GLOCKE_URL,
    $services."tafel-frontend".build.args.VITE_GLOCKE_URL,
    $services."zettel-frontend".build.args.VITE_GLOCKE_URL,
    $services."schrank-frontend".build.args.VITE_GLOCKE_URL
  ] as $browser_glocke_urls
  | $browser_glocke_urls | all(. == $glocke_url))
  and ($services.schloss.build.args.VITE_KUVERT_URL == $services."glocke-backend".environment.KUVERT_ORIGIN)
  and ($services.schloss.build.args.VITE_TAFEL_URL == $services."glocke-backend".environment.TAFEL_ORIGIN)

  # Browser Push (issue #49): the VAPID keypair/subject, the feature flag,
  # and the provider allowlist must reach glocke-backend - and ONLY
  # glocke-backend - at runtime. Public key and feature flag are fetched by
  # the frontend at runtime from GET /notifications/push/status; none of
  # these five vars are ever meant to be baked into a browser build, so
  # every build.args block (frontends and schloss alike) must be completely
  # free of them, not just free of the private key.
  and ($services."glocke-backend".environment.GLOCKE_BROWSER_PUSH_ENABLED == $vapid_enabled)
  and ($services."glocke-backend".environment.GLOCKE_VAPID_SUBJECT == $vapid_subject)
  and ($services."glocke-backend".environment.GLOCKE_VAPID_PUBLIC_KEY == $vapid_public)
  and ($services."glocke-backend".environment.GLOCKE_VAPID_PRIVATE_KEY == $vapid_private)
  and ($services."glocke-backend".environment.GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS == $vapid_hosts)
  and (($vapid_hosts | split(",") | map(select(length > 0)) | length) > 0)
  and ([
    $services[]
    | select(.build.args? != null)
    | .build.args
    | to_entries[]
    | select(
        (.value == $vapid_private)
        or (.value == $vapid_public and .value != "")
        or (.key | test("VAPID"))
      )
  ] | length == 0)
' "$CONFIG" >/dev/null

printf 'Validated %s\n' "$ENV_FILE"
