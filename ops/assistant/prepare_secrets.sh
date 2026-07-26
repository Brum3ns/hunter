#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=${HUNTER_ASSISTANT_REPOSITORY_ROOT:-$(CDPATH= cd -- "$script_dir/../.." && pwd)}
secret_dir="$repository_root/secrets"

umask 077
mkdir -p "$secret_dir"
chmod 0700 "$secret_dir"

# Every hardened Assistant container runs as the fixed identity 1000:1000.
# secrets/README.md's step 2 already chowns the key *files* to 1000:1000, but
# a directory owned by whoever ran this script (root, under sudo, or any
# other non-1000 account) blocks uid 1000 from traversing it regardless of the
# files' own ownership. Fix the directory here too, best-effort: chown to an
# arbitrary uid requires privilege this script may not have.
if chown 1000:1000 "$secret_dir" 2>/dev/null; then
  echo "secrets/ is owned by 1000:1000, matching every hardened Assistant container."
else
  echo "secrets/ could not be chowned to 1000:1000 (this account lacks permission)."
  echo "Run 'sudo chown 1000:1000 $secret_dir' yourself, or uid 1000 in the"
  echo "gateway and web containers will not be able to traverse the mount."
fi

echo "secrets/ is ready. Create assistant_openai_api_key and/or"
echo "assistant_anthropic_api_key at mode 0600 to enable a provider."
echo "An absent or empty file keeps that provider disabled; the chat reports why."
