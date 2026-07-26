#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

skip() {
  echo "$1" >&2
  exit 77
}

fail() {
  echo "network-denial failure: $1" >&2
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  skip "Docker is required for live Assistant network-denial checks"
fi
if ! docker compose version >/dev/null 2>&1; then
  skip "Docker Compose v2 is required for live Assistant network-denial checks"
fi

cd "$repository_root"

sentinel_names=
cleanup() {
  for sentinel_name in $sentinel_names; do
    docker rm -f "$sentinel_name" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT HUP INT TERM

service_id() {
  id=$(docker compose --profile assistant --profile ansible ps -q "$1")
  [ -n "$id" ] || skip "required running service is unavailable: $1"
  running=$(docker inspect --format '{{.State.Running}}' "$id")
  [ "$running" = "true" ] || skip "required service is not running: $1"
  printf '%s\n' "$id"
}

for required_service in \
  web db mongo rabbitmq runner ansible-executor \
  assistant-gateway hunter-mcp assistant-validator assistant-egress
do
  service_id "$required_service" >/dev/null
done

probe_image=$(docker inspect --format '{{.Config.Image}}' "$(service_id assistant-validator)")
[ -n "$probe_image" ] || skip "could not resolve the validator probe image"

start_sentinel() {
  destination_service=$1
  port=$2
  sentinel_name="hunter-assistant-denial-$destination_service-$$"
  destination_id=$(service_id "$destination_service")
  docker run -d \
    --name "$sentinel_name" \
    --network "container:$destination_id" \
    --read-only \
    --user 1000:1000 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --pids-limit 16 \
    --memory 32m \
    --entrypoint /bin/sh \
    "$probe_image" -c "exec httpd -f -p '$port'" >/dev/null
  sentinel_names="$sentinel_names $sentinel_name"
  attempts=0
  until docker exec "$sentinel_name" nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 10 ] || fail "denial sentinel failed to listen for $destination_service"
    sleep 1
  done
}

start_sentinel runner 19001
start_sentinel ansible-executor 19002

probe() {
  source_id=$(service_id "$1")
  shift
  docker run --rm \
    --network "container:$source_id" \
    --read-only \
    --user 1000:1000 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --pids-limit 32 \
    --memory 64m \
    --entrypoint /bin/sh \
    "$probe_image" -c "$1"
}

assert_connects() {
  source_service=$1
  destination=$2
  port=$3
  if ! probe "$source_service" "nc -z -w 3 '$destination' '$port' >/dev/null 2>&1"; then
    fail "$source_service could not reach required peer $destination:$port"
  fi
}

assert_denied_host() {
  source_service=$1
  destination=$2
  port=$3
  label=$4
  if probe "$source_service" "nc -z -w 3 '$destination' '$port' >/dev/null 2>&1"; then
    fail "$source_service reached forbidden $label by DNS/name ($destination:$port)"
  fi
}

service_addresses() {
  docker inspect --format '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' "$(service_id "$1")" |
    sed '/^$/d'
}

assert_denied_service() {
  source_service=$1
  destination_service=$2
  port=$3
  assert_denied_host "$source_service" "$destination_service" "$port" "$destination_service"

  addresses=$(service_addresses "$destination_service")
  [ -n "$addresses" ] || skip "no live address found for $destination_service"
  for address in $addresses; do
    if probe "$source_service" "nc -z -w 3 '$address' '$port' >/dev/null 2>&1"; then
      fail "$source_service reached forbidden $destination_service by direct IP ($address:$port)"
    fi
  done
}

assert_public_denied() {
  source_service=$1
  assert_denied_host "$source_service" api.openai.com 443 "provider Internet"
  assert_denied_host "$source_service" api.anthropic.com 443 "provider Internet"
  assert_denied_host "$source_service" one.one.one.one 443 "public Internet"
  if probe "$source_service" "nc -z -w 3 1.1.1.1 443 >/dev/null 2>&1"; then
    fail "$source_service reached public Internet by direct IP"
  fi
}

assert_private_and_metadata_denied() {
  source_service=$1
  assert_denied_host "$source_service" metadata.google.internal 80 "metadata service"
  for address in 10.255.255.1 172.31.255.1 192.168.255.1 169.254.169.254; do
    if probe "$source_service" "nc -z -w 2 '$address' 80 >/dev/null 2>&1"; then
      fail "$source_service reached forbidden private/metadata address $address"
    fi
  done
}

# Positive controls prove that a blanket network outage cannot make all of the
# negative checks pass.
assert_connects assistant-gateway rabbitmq 5672
assert_connects assistant-gateway hunter-mcp 8080
assert_connects assistant-gateway assistant-egress 3128
assert_connects hunter-mcp web 5000
assert_connects assistant-validator rabbitmq 5672

for destination in web db mongo runner ansible-executor; do
  case "$destination" in
    web) port=5000 ;;
    db) port=5432 ;;
    mongo) port=27017 ;;
    runner) port=19001 ;;
    ansible-executor) port=19002 ;;
  esac
  assert_denied_service assistant-gateway "$destination" "$port"
done
assert_private_and_metadata_denied assistant-gateway

for destination in db mongo runner ansible-executor; do
  case "$destination" in
    db) port=5432 ;;
    mongo) port=27017 ;;
    runner) port=19001 ;;
    ansible-executor) port=19002 ;;
  esac
  assert_denied_service hunter-mcp "$destination" "$port"
done
assert_public_denied hunter-mcp
assert_private_and_metadata_denied hunter-mcp

for destination in web db mongo runner ansible-executor; do
  case "$destination" in
    web) port=5000 ;;
    db) port=5432 ;;
    mongo) port=27017 ;;
    runner) port=19001 ;;
    ansible-executor) port=19002 ;;
  esac
  assert_denied_service assistant-validator "$destination" "$port"
done
assert_public_denied assistant-validator
assert_private_and_metadata_denied assistant-validator

assert_denied_service web assistant-egress 3128

assert_proxy_rejects() {
  destination=$1
  port=$2
  label=$3
  response=$(probe assistant-egress "printf 'CONNECT $destination:$port HTTP/1.1\\r\\nHost: $destination:$port\\r\\n\\r\\n' | nc -w 3 127.0.0.1 3128 2>/dev/null | sed -n '1p'" || true)
  case "$response" in
    *" 403 "*) ;;
    *) fail "egress proxy did not explicitly reject $label" ;;
  esac
}

assert_proxy_rejects example.com 443 "non-provider DNS destination"
assert_proxy_rejects 1.1.1.1 443 "non-provider direct IP destination"
assert_proxy_rejects 10.255.255.1 443 "RFC1918 destination"
assert_proxy_rejects 169.254.169.254 443 "metadata destination"

echo "Assistant live network-denial checks passed."
