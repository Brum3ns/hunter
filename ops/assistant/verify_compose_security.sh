#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker Compose is required for resolved security verification" >&2
  exit 77
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required for resolved security verification" >&2
  exit 77
fi

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM
chmod 0700 "$temporary_dir"

cd "$repository_root"
docker compose config > "$temporary_dir/development.yml"
docker compose -f docker-compose.prod.yaml config > "$temporary_dir/production.yml"
chmod 0600 "$temporary_dir/development.yml" "$temporary_dir/production.yml"

cd "$repository_root/web"
bundle exec ruby test/config/assistant_compose_test.rb

for profile in \
  hunter-assistant-gateway \
  hunter-mcp \
  hunter-assistant-validator \
  hunter-assistant-egress
do
  if [ -r /sys/kernel/security/apparmor/profiles ] &&
      ! grep -q "^$profile " /sys/kernel/security/apparmor/profiles; then
    echo "AppArmor profile is not loaded: $profile" >&2
    exit 1
  fi
done

echo "Resolved development and production Compose security checks passed."
