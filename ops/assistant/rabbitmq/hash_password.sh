#!/bin/sh
set -eu

password_value=$(cat)
if [ -z "$password_value" ]; then
  echo "Cannot hash an empty RabbitMQ password" >&2
  exit 1
fi

salt_b64=$(openssl rand -base64 4 | tr -d '\r\n')
digest_b64=$(
  {
    printf '%s' "$salt_b64" | openssl base64 -d -A
    printf '%s' "$password_value"
  } | openssl dgst -sha256 -binary | openssl base64 -A
)
{
  printf '%s' "$salt_b64" | openssl base64 -d -A
  printf '%s' "$digest_b64" | openssl base64 -d -A
} | openssl base64 -A

