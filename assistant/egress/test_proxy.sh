#!/bin/sh
set -eu

image=${1:-hunter-assistant-egress:test}
network="hunter-assistant-egress-test-$$"
proxy_container="hunter-assistant-egress-test-$$"
tester_image="alpine:3.23"

cleanup() {
  docker rm -f "$proxy_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker network create "$network" >/dev/null
docker run -d --name "$proxy_container" --network "$network" --read-only \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=8m \
  "$image" >/dev/null

for attempt in 1 2 3 4 5; do
  if docker exec "$proxy_container" /usr/sbin/squid -k check -f /etc/squid/squid.conf >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "egress proxy did not become ready" >&2
    exit 1
  fi
  sleep 1
done

connect_through_proxy() {
  url=$1
  docker run --rm --network "$network" "$tester_image" sh -eu -c '
    apk add --no-cache curl >/dev/null
    exec curl --silent --show-error --connect-only --connect-timeout 10 --max-time 20 \
      --proxy "http://'$proxy_container':3128" "$1"
  ' sh "$url"
}

request_through_proxy() {
  url=$1
  docker run --rm --network "$network" "$tester_image" sh -eu -c '
    apk add --no-cache curl >/dev/null
    exec curl --fail --silent --show-error --output /dev/null --connect-timeout 10 --max-time 20 \
      --proxy "http://'$proxy_container':3128" "$1"
  ' sh "$url"
}

expect_allowed() {
  if ! connect_through_proxy "$1"; then
    echo "expected provider destination to be reachable: $1" >&2
    exit 1
  fi
}

expect_denied() {
  if connect_through_proxy "$1"; then
    echo "expected destination to be denied: $1" >&2
    exit 1
  fi
}

# These requests carry no credentials. A provider HTTP error is still a
# successful TLS tunnel, and curl exits zero without --fail.
expect_allowed https://api.openai.com/v1/models
expect_allowed https://api.anthropic.com/v1/messages

if request_through_proxy http://api.openai.com/v1/models; then
  echo "expected plaintext provider request to be denied" >&2
  exit 1
fi
expect_denied https://example.com/
expect_denied https://127.0.0.1/
expect_denied https://10.0.0.1/
expect_denied https://169.254.169.254/latest/meta-data/
expect_denied https://metadata.google.internal/

echo "assistant egress policy checks passed"
