#!/bin/sh
set -eu

secret_path=${RABBITMQ_PROVISION_PASSWORD_FILE:-/run/secrets/assistant_rabbitmq_provision_password}
ready_path=/tmp/hunter-assistant-rabbitmq-ready
definitions_path=/tmp/hunter-assistant-rabbitmq-provisioner.json
rabbit_pid=
watchdog_pid=

cleanup() {
  rm -f "$definitions_path"
  if [ -n "$watchdog_pid" ] && kill -0 "$watchdog_pid" 2>/dev/null; then
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  if [ -n "$rabbit_pid" ] && kill -0 "$rabbit_pid" 2>/dev/null; then
    kill -TERM "$rabbit_pid" 2>/dev/null || true
    wait "$rabbit_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM INT

if [ ! -f "$secret_path" ] || [ -L "$secret_path" ]; then
  echo "RabbitMQ provisioning credential unavailable" >&2
  exit 1
fi

password=$(tr -d '\r\n' < "$secret_path")
case "$password" in
  *[!A-Za-z0-9+/=_-]*)
    echo "RabbitMQ provisioning credential rejected" >&2
    exit 1
    ;;
esac
force_reprovision=${ASSISTANT_RABBITMQ_REPROVISION:-false}
case "$force_reprovision" in
  true|false) ;;
  *)
    echo "ASSISTANT_RABBITMQ_REPROVISION must be true or false" >&2
    exit 1
    ;;
esac

assistant_topology_complete() {
  users=$(rabbitmqctl -q --formatter=json list_users 2>/dev/null) || return 1
  vhosts=$(rabbitmqctl -q --formatter=json list_vhosts name 2>/dev/null) || return 1
  permissions=$(rabbitmqctl -q --formatter=json list_permissions -p /hunter-assistant 2>/dev/null) || return 1
  exchanges=$(rabbitmqctl -q --formatter=json list_exchanges -p /hunter-assistant \
    name type durable auto_delete internal arguments 2>/dev/null) || return 1
  queues=$(rabbitmqctl -q --formatter=json list_queues -p /hunter-assistant \
    name durable auto_delete arguments 2>/dev/null) || return 1
  bindings=$(rabbitmqctl -q --formatter=json list_bindings -p /hunter-assistant \
    source_name destination_name destination_kind routing_key arguments 2>/dev/null) || return 1

  printf '%s' "$vhosts" | jq -e '
    [.[] | select(.name == "/hunter-assistant")] | length == 1
  ' >/dev/null || return 1
  printf '%s' "$users" | jq -e '
    def restricted($name):
      [.[] | select(.user == $name and ((.tags | length) == 0))] | length == 1;
    restricted("hunter-assistant-rails") and
    restricted("hunter-assistant-gateway") and
    restricted("hunter-assistant-validator") and
    ([.[] | select(.user == "assistant-provisioner")] | length == 0)
  ' >/dev/null || return 1
  printf '%s' "$permissions" | jq -e '
    def exact($user; $write; $read):
      [.[] | select(
        .user == $user and .configure == "^$" and
        .write == $write and .read == $read
      )] | length == 1;
    length == 3 and
    exact("hunter-assistant-rails";
      "^(assistant\\.turns|assistant\\.validations)$";
      "^(assistant\\.rails\\.events|assistant\\.rails\\.validation_events)$") and
    exact("hunter-assistant-gateway";
      "^assistant\\.events$"; "^assistant\\.gateway\\.turns$") and
    exact("hunter-assistant-validator";
      "^assistant\\.validation_events$"; "^assistant\\.validator\\.requests$")
  ' >/dev/null || return 1
  printf '%s' "$exchanges" | jq -e '
    def exact($name):
      [.[] | select(
        .name == $name and .type == "direct" and .durable == false and
        .auto_delete == false and .internal == false and (.arguments | length) == 0
      )] | length == 1;
    ([.[] | select((.name == "" or (.name | startswith("amq."))) | not)] | length == 4) and
    exact("assistant.turns") and exact("assistant.events") and
    exact("assistant.validations") and exact("assistant.validation_events")
  ' >/dev/null || return 1
  printf '%s' "$queues" | jq -e '
    def has_x_expires:
      if (.arguments | type) == "object" then
        ((.arguments | length) == 1 and
          ((.arguments["x-expires"] | tonumber?) == 3600000))
      elif (.arguments | type) == "array" then
        ((.arguments | length) == 1 and any(.arguments[]?;
          (type == "array" and .[0] == "x-expires" and ((.[-1] | tonumber?) == 3600000)) or
          (type == "object" and .key == "x-expires" and ((.value | tonumber?) == 3600000))
        ))
      else false end;
    def exact($name):
      [.[] | select(
        .name == $name and .durable == false and .auto_delete == false and
        has_x_expires
      )] | length == 1;
    length == 4 and exact("assistant.gateway.turns") and
    exact("assistant.rails.events") and exact("assistant.validator.requests") and
    exact("assistant.rails.validation_events")
  ' >/dev/null || return 1
  printf '%s' "$bindings" | jq -e '
    def exact($source; $destination; $routing_key):
      [.[] | select(
        .source_name == $source and .destination_name == $destination and
        .destination_kind == "queue" and .routing_key == $routing_key and
        (.arguments | length) == 0
      )] | length == 1;
    ([.[] | select(.source_name != "")] | length == 4) and
    exact("assistant.turns"; "assistant.gateway.turns"; "assistant.gateway.turns") and
    exact("assistant.events"; "assistant.rails.events"; "assistant.rails.events") and
    exact("assistant.validations"; "assistant.validator.requests"; "assistant.validator.requests") and
    exact("assistant.validation_events"; "assistant.rails.validation_events"; "assistant.rails.validation_events")
  ' >/dev/null || return 1
}

server_running() {
  kill -0 "$rabbit_pid" 2>/dev/null || return 1
  # A child that has exited but is not yet reaped still accepts signals, so treat
  # a zombie as dead instead of waiting out the whole deadline.
  state=$(sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$rabbit_pid/status" 2>/dev/null) || state=
  [ -n "$state" ] && [ "$state" != "Z" ]
}

# rabbitmqctl exits 69 (EX_UNAVAILABLE) until the node registers with epmd, and
# its own --timeout does not cover that window. Poll rather than trusting a single
# call, so a broker still in prelaunch is never mistaken for a failed one.
await_rabbit_startup() {
  startup_deadline=$(( $(date +%s) + 180 ))
  while :; do
    if ! server_running; then
      echo "RabbitMQ server process exited during startup" >&2
      return 1
    fi
    if rabbitmqctl -q await_startup --timeout 15 >/dev/null 2>&1; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$startup_deadline" ]; then
      echo "RabbitMQ did not finish starting within 180s" >&2
      return 1
    fi
    sleep 2
  done
}

rm -f "$ready_path" "$definitions_path"
/usr/local/bin/docker-entrypoint.sh "$@" &
rabbit_pid=$!
await_rabbit_startup
vhosts=$(rabbitmqctl -q list_vhosts name --formatter=json)
if printf '%s' "$vhosts" | jq -e 'any(.[]?; .name == "/hunter-assistant")' >/dev/null; then
  rabbitmqctl -q trace_off -p /hunter-assistant >/dev/null
fi
unset vhosts

needs_provision=false
if [ -n "$password" ] && { [ "$force_reprovision" = true ] || ! assistant_topology_complete; }; then
  needs_provision=true
fi
if [ "$needs_provision" = true ]; then
  umask 077
  provision_hash=$(printf '%s' "$password" | /usr/local/bin/hunter-assistant-rabbitmq-hash-password)
  printf '%s' \
    "{\"users\":[{\"name\":\"assistant-provisioner\",\"password_hash\":\"$provision_hash\",\"hashing_algorithm\":\"rabbit_password_hashing_sha256\",\"tags\":[\"administrator\"]}]}" \
    > "$definitions_path"
  rabbitmqctl -q delete_user assistant-provisioner >/dev/null 2>&1 || true
  rabbitmqctl import_definitions "$definitions_path" >/dev/null
  rm -f "$definitions_path"
  unset provision_hash
  (
    sleep 120
    rabbitmqctl -q delete_user assistant-provisioner >/dev/null 2>&1 || true
  ) &
  watchdog_pid=$!
fi
unset password force_reprovision needs_provision

: > "$ready_path"
chmod 0444 "$ready_path"
set +e
wait "$rabbit_pid"
status=$?
set -e
rabbit_pid=
exit "$status"
