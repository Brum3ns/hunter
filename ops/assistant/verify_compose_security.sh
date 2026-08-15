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

# The Assistant services no longer reference a custom AppArmor profile
# (Docker's built-in docker-default profile applies instead; see
# docs/superpowers/specs/2026-07-26-hunter-assistant-zero-step-activation-delta.md).
# What remains a real, host-independent guarantee is each service's seccomp
# profile: it must still be declared in the resolved security_opt and the
# referenced JSON file must exist on disk.
cd "$repository_root"
for resolved in "$temporary_dir/development.yml" "$temporary_dir/production.yml"; do
  ruby -ryaml -e '
    resolved_path, repository_root = ARGV
    services = YAML.safe_load(File.read(resolved_path)).fetch("services")
    seccomp_profiles = {
      "hunter-mcp" => "mcp",
      "assistant-claude" => "claude",
      "assistant-codex" => "codex"
    }

    seccomp_profiles.each do |service_name, profile_name|
      options = services.fetch(service_name).fetch("security_opt", [])
      option = options.find { |entry| entry.start_with?("seccomp=") }
      abort "#{resolved_path}: #{service_name} has no seccomp profile in security_opt" unless option

      path = option.split("=", 2).last
      expected = "./ops/assistant/seccomp/#{profile_name}.json"
      abort "#{resolved_path}: #{service_name} uses unexpected seccomp profile #{path}" unless path == expected
      resolved_json = File.expand_path(path, repository_root)
      abort "#{resolved_path}: #{service_name} seccomp profile #{path} does not exist" unless File.exist?(resolved_json)
    end
  ' "$resolved" "$repository_root"
done

echo "Resolved development and production Compose security checks passed."
