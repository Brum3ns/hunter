#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=${HUNTER_ASSISTANT_REPOSITORY_ROOT:-$(CDPATH= cd -- "$script_dir/../.." && pwd)}
secret_dir="$repository_root/secrets"

umask 077
mkdir -p "$secret_dir"
chmod 0700 "$secret_dir"

echo "secrets/ is ready. Create assistant_openai_api_key and/or"
echo "assistant_anthropic_api_key at mode 0600 to enable a provider."
echo "An absent or empty file keeps that provider disabled; the chat reports why."
