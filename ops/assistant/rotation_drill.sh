#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

skip() {
  echo "$1" >&2
  exit 77
}

fail() {
  echo "rotation-drill failure: $1" >&2
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  skip "Docker is required for the isolated Assistant credential-rotation drill"
fi
if ! docker compose version >/dev/null 2>&1; then
  skip "Docker Compose v2 is required for the isolated Assistant credential-rotation drill"
fi

temporary_dir=$(mktemp -d)
drill_suffix=$$
network_name="hunter-assistant-rotation-$drill_suffix"
volume_name="hunter-assistant-rotation-$drill_suffix"
rabbit_name="hunter-assistant-rotation-rabbit-$drill_suffix"

cleanup() {
  docker rm -f "$rabbit_name" >/dev/null 2>&1 || true
  docker volume rm "$volume_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM
chmod 0700 "$temporary_dir"

cd "$repository_root"
rabbit_id=$(docker compose ps -q rabbitmq)
web_id=$(docker compose ps -q web)
[ -n "$rabbit_id" ] || skip "the built/running RabbitMQ service is required for the drill"
[ -n "$web_id" ] || skip "the built/running web service is required for the drill"
rabbit_image=$(docker inspect --format '{{.Config.Image}}' "$rabbit_id")
web_image=$(docker inspect --format '{{.Config.Image}}' "$web_id")
[ -n "$rabbit_image" ] || skip "could not resolve the RabbitMQ image"
[ -n "$web_image" ] || skip "could not resolve the web image"

HUNTER_ASSISTANT_REPOSITORY_ROOT="$temporary_dir/old" "$script_dir/generate_secrets.sh" dev >/dev/null
HUNTER_ASSISTANT_REPOSITORY_ROOT="$temporary_dir/new" "$script_dir/generate_secrets.sh" dev >/dev/null
old_dir="$temporary_dir/old/secrets/dev"
new_dir="$temporary_dir/new/secrets/dev"

rabbit_secret_names="
assistant_rabbitmq_provision_password
assistant_rails_amqp_password
assistant_gateway_amqp_password
assistant_validator_amqp_password
"

for name in $rabbit_secret_names; do
  old_file="$old_dir/$name"
  new_file="$new_dir/$name"
  [ "$(stat -c '%a' "$old_file")" = "600" ] || fail "$name old source mode"
  [ "$(stat -c '%a' "$new_file")" = "600" ] || fail "$name new source mode"
  cmp -s "$old_file" "$new_file" && fail "$name did not rotate"
done

docker network create --internal "$network_name" >/dev/null
docker volume create "$volume_name" >/dev/null

start_rabbit() {
  secret_dir=$1
  force_reprovision=$2
  docker run -d \
    --name "$rabbit_name" \
    --hostname hunter-assistant-rotation-rabbit \
    --network "$network_name" \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
    --tmpfs /var/run/rabbitmq:rw,nosuid,nodev,size=16m \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --mount "type=volume,source=$volume_name,target=/var/lib/rabbitmq" \
    --mount "type=bind,source=$secret_dir/assistant_rabbitmq_provision_password,target=/run/secrets/assistant_rabbitmq_provision_password,readonly" \
    --env ASSISTANT_ENABLED=false \
    --env "ASSISTANT_RABBITMQ_REPROVISION=$force_reprovision" \
    --env RABBITMQ_DEFAULT_USER=hunter-rotation-admin \
    --env RABBITMQ_DEFAULT_PASS=hunter-rotation-admin-test-only \
    "$rabbit_image" >/dev/null

  attempts=0
  until docker exec "$rabbit_name" sh -c \
      'rabbitmq-diagnostics -q ping && test -f /tmp/hunter-assistant-rabbitmq-ready' \
      >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail "isolated RabbitMQ did not become ready"
    sleep 2
  done
}

run_provisioner() {
  secret_dir=$1
  docker run --rm \
    --network "$network_name" \
    --user 1000:1000 \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,uid=1000,gid=1000 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --mount "type=bind,source=$secret_dir/assistant_rabbitmq_provision_password,target=/run/secrets/assistant_rabbitmq_provision_password,readonly" \
    --mount "type=bind,source=$secret_dir/assistant_rails_amqp_password,target=/run/secrets/assistant_rails_amqp_password,readonly" \
    --mount "type=bind,source=$secret_dir/assistant_gateway_amqp_password,target=/run/secrets/assistant_gateway_amqp_password,readonly" \
    --mount "type=bind,source=$secret_dir/assistant_validator_amqp_password,target=/run/secrets/assistant_validator_amqp_password,readonly" \
    --env RABBITMQ_MANAGEMENT_URL="http://$rabbit_name:15672" \
    --env RABBITMQ_AMQP_HOST="$rabbit_name" \
    --env RABBITMQ_PROVISION_USERNAME=assistant-provisioner \
    --env RABBITMQ_PROVISION_PASSWORD_FILE=/run/secrets/assistant_rabbitmq_provision_password \
    --env ASSISTANT_RAILS_AMQP_PASSWORD_FILE=/run/secrets/assistant_rails_amqp_password \
    --env ASSISTANT_GATEWAY_AMQP_PASSWORD_FILE=/run/secrets/assistant_gateway_amqp_password \
    --env ASSISTANT_VALIDATOR_AMQP_PASSWORD_FILE=/run/secrets/assistant_validator_amqp_password \
    --entrypoint bundle \
    "$web_image" exec ruby /app/ops/assistant/provision_rabbitmq.rb >/dev/null
}

assert_authentication() {
  expectation=$1
  secret_dir=$2
  username=$3
  secret_name=$4
  if docker run --rm \
      --network "$network_name" \
      --user 1000:1000 \
      --read-only \
      --tmpfs /tmp:rw,noexec,nosuid,nodev,size=8m,uid=1000,gid=1000 \
      --cap-drop ALL \
      --security-opt no-new-privileges:true \
      --mount "type=bind,source=$secret_dir/$secret_name,target=/run/rotation-secret,readonly" \
      --env RABBITMQ_AMQP_HOST="$rabbit_name" \
      --env RABBITMQ_AMQP_USER="$username" \
      --entrypoint bundle \
      "$web_image" exec ruby -rbunny -rlogger -e '
        connection = Bunny.new(
          host: ENV.fetch("RABBITMQ_AMQP_HOST"),
          vhost: "/hunter-assistant",
          user: ENV.fetch("RABBITMQ_AMQP_USER"),
          password: File.binread("/run/rotation-secret").strip,
          connection_timeout: 3,
          automatically_recover: false,
          logger: Logger.new(File::NULL)
        )
        connection.start
        connection.close
      ' >/dev/null 2>&1; then
    result=success
  else
    result=failure
  fi
  [ "$result" = "$expectation" ] || fail "$username authentication expected $expectation"
}

assert_all_authenticate() {
  expectation=$1
  secret_dir=$2
  assert_authentication "$expectation" "$secret_dir" hunter-assistant-rails assistant_rails_amqp_password
  assert_authentication "$expectation" "$secret_dir" hunter-assistant-gateway assistant_gateway_amqp_password
  assert_authentication "$expectation" "$secret_dir" hunter-assistant-validator assistant_validator_amqp_password
}

start_rabbit "$old_dir" true
run_provisioner "$old_dir"
assert_all_authenticate success "$old_dir"
docker exec "$rabbit_name" rabbitmqctl -q list_users --formatter=json |
  grep -q 'assistant-provisioner' && fail "temporary provisioner survived initial provisioning"

docker rm -f "$rabbit_name" >/dev/null
start_rabbit "$new_dir" true
run_provisioner "$new_dir"
assert_all_authenticate failure "$old_dir"
assert_all_authenticate success "$new_dir"
docker exec "$rabbit_name" rabbitmqctl -q list_users --formatter=json |
  grep -q 'assistant-provisioner' && fail "temporary provisioner survived rotation"

# A final ordinary restart proves the rotated topology is complete without a
# reprovisioning override or temporary administrator.
docker rm -f "$rabbit_name" >/dev/null
start_rabbit "$new_dir" false
assert_all_authenticate success "$new_dir"
docker exec "$rabbit_name" rabbitmqctl -q list_users --formatter=json |
  grep -q 'assistant-provisioner' && fail "ordinary restart recreated the provisioner"

echo "Assistant isolated RabbitMQ credential-rotation drill passed; old credentials were rejected."
