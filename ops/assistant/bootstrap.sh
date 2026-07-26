#!/bin/sh
set -eu

target=${ASSISTANT_SECRET_TARGET:-/run/assistant/secrets}
umask 077
mkdir -p "$target"

generate() {
  path="$target/$1"
  [ -e "$path" ] && return 0

  temporary=$(mktemp "$target/.bootstrap.XXXXXX")
  openssl rand -base64 32 | tr -d '\n' > "$temporary"
  if [ ! -s "$temporary" ]; then
    rm -f "$temporary"
    echo "failed to generate $1" >&2
    exit 1
  fi
  chmod 0400 "$temporary"
  if ! ln "$temporary" "$path" 2>/dev/null; then
    rm -f "$temporary"
    return 0
  fi
  rm -f "$temporary"
}

generate assistant_rabbitmq_provision_password
generate assistant_rails_amqp_password
generate assistant_gateway_amqp_password
generate assistant_validator_amqp_password
generate assistant_gateway_mcp_token
