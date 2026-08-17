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

docker compose --env-file "$ENV_FILE" config --format json >"$CONFIG"

jq -e '
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
  and ($services.schloss.build.args.VITE_KUVERT_URL == $services."glocke-backend".environment.KUVERT_ORIGIN)
  and ($services.schloss.build.args.VITE_TAFEL_URL == $services."glocke-backend".environment.TAFEL_ORIGIN)
' "$CONFIG" >/dev/null

printf 'Validated %s\n' "$ENV_FILE"
