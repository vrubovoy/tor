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
unset WACHTER_AGENT_TOKEN
unset DOCKER_GID
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
DOCKER_GID=
while IFS='=' read -r name value; do
	case "$name" in
	GLOCKE_URL) GLOCKE_URL=$value ;;
	GLOCKE_BROWSER_PUSH_ENABLED) GLOCKE_BROWSER_PUSH_ENABLED=$value ;;
	GLOCKE_VAPID_SUBJECT) GLOCKE_VAPID_SUBJECT=$value ;;
	GLOCKE_VAPID_PUBLIC_KEY) GLOCKE_VAPID_PUBLIC_KEY=$value ;;
	GLOCKE_VAPID_PRIVATE_KEY) GLOCKE_VAPID_PRIVATE_KEY=$value ;;
	GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS) GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS=$value ;;
	DOCKER_GID) DOCKER_GID=$value ;;
	esac
done <"$ENV_FILE"

if [ -z "$GLOCKE_URL" ]; then
	printf 'GLOCKE_URL is missing from %s\n' "$ENV_FILE" >&2
	exit 1
fi

case "$DOCKER_GID" in
'' | *[!0-9]*)
	printf 'DOCKER_GID must be a positive numeric group ID in %s\n' "$ENV_FILE" >&2
	exit 1
	;;
esac

if [ "$DOCKER_GID" -le 0 ]; then
	printf 'DOCKER_GID must be greater than zero in %s\n' "$ENV_FILE" >&2
	exit 1
fi

# Committed examples must be safe to start without accidentally enabling
# outbound Browser Push. README.md documents the separate opt-in procedure.
if [ "$GLOCKE_BROWSER_PUSH_ENABLED" != false ] ||
	[ -n "$GLOCKE_VAPID_SUBJECT" ] || [ -n "$GLOCKE_VAPID_PUBLIC_KEY" ] ||
	[ -n "$GLOCKE_VAPID_PRIVATE_KEY" ] || [ -n "$GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS" ]; then
	printf 'Browser Push must be disabled with blank VAPID/allowlist values in %s\n' "$ENV_FILE" >&2
	exit 1
fi

node "$(dirname "$0")/validate-public-origin.mjs" "$GLOCKE_URL"

if ! docker compose --env-file "$ENV_FILE" \
	--profile kuvert --profile tafel --profile zettel --profile glocke \
	--profile schrank --profile herold --profile wachter config --quiet; then
	printf 'docker compose config --quiet failed for %s\n' "$ENV_FILE" >&2
	exit 1
fi

docker compose --env-file "$ENV_FILE" \
	--profile kuvert --profile tafel --profile zettel --profile glocke \
	--profile schrank --profile herold --profile wachter config --format json >"$CONFIG"

jq -e --arg glocke_url "$GLOCKE_URL" \
  --arg vapid_enabled "$GLOCKE_BROWSER_PUSH_ENABLED" \
  --arg vapid_subject "$GLOCKE_VAPID_SUBJECT" \
  --arg vapid_public "$GLOCKE_VAPID_PUBLIC_KEY" \
  --arg vapid_private "$GLOCKE_VAPID_PRIVATE_KEY" \
  --arg vapid_hosts "$GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS" \
  --arg docker_gid "$DOCKER_GID" '
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
    $services."glocke-frontend".environment.SCHLOSS_URL,
    $services."glocke-frontend".environment.SCHLUSSEL_WEB_URL,
    $services.schloss.environment.KUVERT_URL,
    $services.schloss.environment.TAFEL_URL,
    $services.schloss.environment.ZETTEL_URL,
    $services.schloss.environment.GLOCKE_URL,
    $services.schloss.environment.SCHRANK_URL,
    $services.schloss.environment.HEROLD_URL
  ] | join(",")))
  and ([
    $services.schloss.environment.GLOCKE_URL,
    $services."schlussel-frontend".environment.GLOCKE_URL,
    $services."kuvert-frontend".environment.GLOCKE_URL,
    $services."tafel-frontend".environment.GLOCKE_URL,
    $services."zettel-frontend".environment.GLOCKE_URL,
    $services."schrank-frontend".environment.GLOCKE_URL,
    $services."herold-frontend".environment.GLOCKE_URL
  ] as $browser_glocke_urls
  | $browser_glocke_urls | all(. == $glocke_url))
  and ($services.schloss.environment.KUVERT_URL == $services."glocke-backend".environment.KUVERT_ORIGIN)
  and ($services.schloss.environment.TAFEL_URL == $services."glocke-backend".environment.TAFEL_ORIGIN)
  and ([
    "schloss", "schlussel-frontend", "kuvert-frontend", "tafel-frontend",
    "zettel-frontend", "glocke-frontend", "schrank-frontend", "herold-frontend"
  ] | all(. as $service | $services[$service].build.args == null))

  # Schlussel owns fixed internal registries for platform exports and account
  # deletion. Assert all targets, including the newer Schrank/Herold entries,
  # so request input or a public URL can never become a dispatch destination.
  and ([
    $services.schlussel.environment.KUVERT_EXPORT_URL,
    $services.schlussel.environment.TAFEL_EXPORT_URL,
    $services.schlussel.environment.ZETTEL_EXPORT_URL,
    $services.schlussel.environment.GLOCKE_EXPORT_URL,
    $services.schlussel.environment.SCHRANK_EXPORT_URL,
    $services.schlussel.environment.HEROLD_EXPORT_URL
  ] == [
    "http://kuvert-backend:3001/exports/me",
    "http://tafel-backend:3002/exports/me",
    "http://zettel-backend:3003/exports/me",
    "http://glocke-backend:3004/exports/me",
    "http://schrank-backend:3005/exports/me",
    "http://herold-backend:3006/exports/me"
  ])
  and ([
    $services.schlussel.environment.KUVERT_DELETION_URL,
    $services.schlussel.environment.TAFEL_DELETION_URL,
    $services.schlussel.environment.ZETTEL_DELETION_URL,
    $services.schlussel.environment.GLOCKE_DELETION_URL,
    $services.schlussel.environment.SCHRANK_DELETION_URL,
    $services.schlussel.environment.HEROLD_DELETION_URL
  ] == [
    "http://kuvert-backend:3001/internal/v1/account-deletions",
    "http://tafel-backend:3002/internal/v1/account-deletions",
    "http://zettel-backend:3003/internal/v1/account-deletions",
    "http://glocke-backend:3004/internal/v1/account-deletions",
    "http://schrank-backend:3005/internal/v1/account-deletions",
    "http://herold-backend:3006/internal/v1/account-deletions"
  ])
  and ([
    $services.schlussel.environment.DELETION_DISPATCH_INTERVAL_MS,
    $services.schlussel.environment.DELETION_LEASE_MS,
    $services.schlussel.environment.DELETION_FETCH_TIMEOUT_MS,
    $services.schlussel.environment.DELETION_WORKER_STOP_TIMEOUT_MS,
    $services.schlussel.environment.DELETION_MAX_ATTEMPTS,
    $services.schlussel.environment.DELETION_RETRY_BASE_DELAY_MS,
    $services.schlussel.environment.DELETION_RETRY_MAX_DELAY_MS
  ] == ["1000", "30000", "10000", "5000", "8", "1000", "900000"])
  and (["kuvert-backend", "tafel-backend", "zettel-backend", "glocke-backend", "schrank-backend", "herold-backend"]
    | all(. as $service
      | $services[$service].environment.SCHLUSSEL_JWKS_URL == "http://schlussel:4000/.well-known/jwks.json"
      and $services[$service].environment.JWT_ISSUER == "schlussel"
      and ($services[$service].networks | has("schloss-net"))))

  # Wächter API can reach both the platform and its private agent, while the
  # Docker-socket agent is isolated to the internal network. The shared token
  # is required and identical at both ends.
  and ($services.wachter.environment.WACHTER_AGENT_URL == "http://wachter-agent:3008")
  and ($services.wachter.environment.WACHTER_AGENT_TOKEN | type == "string" and length >= 32)
  and ($services.wachter.environment.WACHTER_AGENT_TOKEN == $services."wachter-agent".environment.WACHTER_AGENT_TOKEN)
  and (($services.wachter.networks | keys | sort) == ["schloss-net", "wachter-internal"])
  and (($services."wachter-agent".networks | keys) == ["wachter-internal"])
  and (.networks."wachter-internal".internal == true)
  and ($services."wachter-agent".group_add == [$docker_gid])
  and ($services.wachter.group_add == null)

  # Only stateless browser containers are restartable. Critical=false is
  # explicit on each one because the agent gives critical=true precedence.
  and ([
    $services | to_entries[]
    | select(.value.labels["hof.wachter.restartable"] == "true")
    | .key
  ] | sort == [
    "glocke-frontend", "herold-frontend", "kuvert-frontend",
    "schlussel-frontend", "schrank-frontend", "tafel-frontend",
    "zettel-frontend"
  ])
  and ([
    $services | to_entries[]
    | select(.value.labels["hof.wachter.restartable"] == "true")
    | .value.labels["hof.wachter.critical"]
  ] | all(. == "false"))
  and ([
    "gateway", "schloss", "schlussel", "kuvert-backend",
    "tafel-backend", "zettel-backend", "glocke-backend",
    "schrank-backend", "herold-backend", "wachter", "wachter-agent"
  ] | all(. as $service
    | $services[$service].labels["hof.wachter.critical"] == "true"
    and $services[$service].labels["hof.wachter.restartable"] != "true"))

  # Browser Push examples resolve to a disabled backend. None of these values
  # may enter a frontend build; the synthetic enabled mode is tested by
  # validate-push-config.sh.
  and ($services."glocke-backend".environment.GLOCKE_BROWSER_PUSH_ENABLED == $vapid_enabled)
  and ($services."glocke-backend".environment.GLOCKE_VAPID_SUBJECT == $vapid_subject)
  and ($services."glocke-backend".environment.GLOCKE_VAPID_PUBLIC_KEY == $vapid_public)
  and ($services."glocke-backend".environment.GLOCKE_VAPID_PRIVATE_KEY == $vapid_private)
  and ($services."glocke-backend".environment.GLOCKE_PUSH_ALLOWED_ENDPOINT_HOSTS == $vapid_hosts)
  and ($vapid_enabled == "false")
  and ($vapid_subject == "")
  and ($vapid_public == "")
  and ($vapid_private == "")
  and ($vapid_hosts == "")
  and ([
    $services[]
    | select(.build.args? != null)
    | .build.args
    | to_entries[]
    | select(
        (.key | test("VAPID|BROWSER_PUSH|PUSH_ALLOWED"))
      )
  ] | length == 0)
' "$CONFIG" >/dev/null

printf 'Validated %s\n' "$ENV_FILE"
