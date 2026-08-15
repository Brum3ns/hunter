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
  id=$(docker compose --profile ansible ps -q "$1")
  [ -n "$id" ] || skip "required running service is unavailable: $1"
  running=$(docker inspect --format '{{.State.Running}}' "$id")
  [ "$running" = "true" ] || skip "required service is not running: $1"
  printf '%s\n' "$id"
}

for required_service in \
  web db mongo runner ansible-executor \
  assistant-codex assistant-claude hunter-mcp
do
  service_id "$required_service" >/dev/null
done

probe_image=$(docker inspect --format '{{.Config.Image}}' "$(service_id assistant-codex)")
[ -n "$probe_image" ] || skip "could not resolve the Codex probe image"

connection_probe='
const net = require("net");
const host = process.argv[1];
const port = Number(process.argv[2]);
const socket = net.connect({ host, port });
const timer = setTimeout(() => { socket.destroy(); process.exit(1); }, 3000);
socket.once("connect", () => {
  clearTimeout(timer);
  socket.destroy();
  process.exit(0);
});
socket.once("error", () => {
  clearTimeout(timer);
  process.exit(1);
});
'

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
    --entrypoint node \
    "$probe_image" -e \
    'require("net").createServer(() => {}).listen(Number(process.argv[1]), "127.0.0.1")' \
    "$port" >/dev/null
  sentinel_names="$sentinel_names $sentinel_name"
  attempts=0
  until docker exec "$sentinel_name" node -e "$connection_probe" \
    127.0.0.1 "$port" >/dev/null 2>&1
  do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 10 ] || fail "denial sentinel failed to listen for $destination_service"
    sleep 1
  done
}

start_sentinel runner 19001
start_sentinel ansible-executor 19002

probe_connection() {
  source_id=$(service_id "$1")
  destination=$2
  port=$3
  docker run --rm \
    --network "container:$source_id" \
    --read-only \
    --user 1000:1000 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --pids-limit 32 \
    --memory 64m \
    --entrypoint node \
    "$probe_image" -e "$connection_probe" "$destination" "$port"
}

assert_connects() {
  source_service=$1
  destination=$2
  port=$3
  if ! probe_connection "$source_service" "$destination" "$port"; then
    fail "$source_service could not reach required peer $destination:$port"
  fi
}

assert_denied_host() {
  source_service=$1
  destination=$2
  port=$3
  label=$4
  if probe_connection "$source_service" "$destination" "$port"; then
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
    if probe_connection "$source_service" "$address" "$port"; then
      fail "$source_service reached forbidden $destination_service by direct IP ($address:$port)"
    fi
  done
}

assert_public_denied() {
  source_service=$1
  assert_denied_host "$source_service" api.openai.com 443 "provider Internet"
  assert_denied_host "$source_service" api.anthropic.com 443 "provider Internet"
  assert_denied_host "$source_service" one.one.one.one 443 "public Internet"
  if probe_connection "$source_service" 1.1.1.1 443; then
    fail "$source_service reached public Internet by direct IP"
  fi
}

assert_private_and_metadata_denied() {
  source_service=$1
  assert_denied_host "$source_service" metadata.google.internal 80 "metadata service"
  for address in 10.255.255.1 172.31.255.1 192.168.255.1 169.254.169.254; do
    if probe_connection "$source_service" "$address" 80; then
      fail "$source_service reached forbidden private/metadata address $address"
    fi
  done
}

# Positive controls prove that a blanket network outage cannot make all of the
# negative checks pass. Both direct runners must reach only the authenticated
# Hunter MCP service on their internal Hunter-facing path. The Rails-facing
# networks are bidirectional at the transport layer; authorization, not network
# directionality, protects Rails from runner-initiated requests.
assert_connects web assistant-codex 8084
assert_connects web assistant-claude 8083
assert_connects assistant-codex hunter-mcp 8080
assert_connects assistant-claude hunter-mcp 8080
assert_connects hunter-mcp web 5000

for source_service in assistant-codex assistant-claude; do
  for destination in db mongo runner ansible-executor; do
    case "$destination" in
      db) port=5432 ;;
      mongo) port=27017 ;;
      runner) port=19001 ;;
      ansible-executor) port=19002 ;;
    esac
    assert_denied_service "$source_service" "$destination" "$port"
  done
done

assert_denied_service assistant-codex assistant-claude 8083
assert_denied_service assistant-claude assistant-codex 8084

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

echo "Assistant live network-denial checks passed."
