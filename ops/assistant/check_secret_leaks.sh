#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
configuration="$script_dir/gitleaks.toml"

skip() {
  echo "$1" >&2
  exit 77
}

fail() {
  echo "secret-leak failure: $1" >&2
  exit 1
}

if ! command -v git >/dev/null 2>&1; then
  skip "Git is required for Assistant secret-leak checks"
fi
if ! command -v gitleaks >/dev/null 2>&1; then
  skip "gitleaks is required for Assistant secret-leak checks"
fi
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  skip "Docker Compose v2 is required for Assistant log, image, and resolved-config secret checks"
fi

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM
chmod 0700 "$temporary_dir"
cd "$repository_root"

tracked_secret_sources=$(git ls-files 'secrets/*' |
  grep -v -e '/\.keep$' -e '^secrets/README\.md$' -e '^secrets/examples/')
[ -z "$tracked_secret_sources" ] || fail "a deployment secret source is tracked by Git"

git check-ignore -q "secrets/hunter-assistant-ignore-probe" ||
  fail "secrets is not protected by .gitignore"

# Scan both committed history and the current working tree. Redaction is
# mandatory so a finding cannot echo a credential into CI output.
gitleaks git --redact --no-banner --config "$configuration"
mkdir "$temporary_dir/worktree"
git ls-files --cached --others --exclude-standard -z > "$temporary_dir/worktree-files"
tar --null --files-from="$temporary_dir/worktree-files" -cf "$temporary_dir/worktree.tar"
tar -xf "$temporary_dir/worktree.tar" -C "$temporary_dir/worktree"
gitleaks dir --redact --no-banner --config "$configuration" "$temporary_dir/worktree"

docker compose config > "$temporary_dir/development-compose.yml"
docker compose -f docker-compose.prod.yaml config > "$temporary_dir/production-compose.yml"
docker compose --profile assistant logs --no-color > "$temporary_dir/assistant.log"
chmod 0600 "$temporary_dir"/*

images_file="$temporary_dir/images"
: > "$images_file"
for service in \
  hunter-mcp assistant-validator assistant-gateway
do
  container_id=$(docker compose --profile assistant ps -q "$service")
  [ -n "$container_id" ] || skip "required running Assistant service is unavailable: $service"
  image=$(docker inspect --format '{{.Image}}' "$container_id")
  grep -Fqx "$image" "$images_file" || printf '%s\n' "$image" >> "$images_file"
done

while IFS= read -r image; do
  docker history --no-trunc --format '{{.CreatedBy}}' "$image" >> "$temporary_dir/image-history"
done < "$images_file"
chmod 0600 "$temporary_dir/image-history"
mkdir "$temporary_dir/image-archive"
xargs docker image save --output "$temporary_dir/images.tar" < "$images_file"
tar -xf "$temporary_dir/images.tar" -C "$temporary_dir/image-archive"

secret_files=
for candidate in secrets/*; do
  [ -f "$candidate" ] || continue
  [ -s "$candidate" ] || continue
  case "$candidate" in
    secrets/README.md) continue ;;
  esac
  secret_files="$secret_files $candidate"
done

for secret_file in $secret_files; do
  permissions=$(stat -c '%a' "$secret_file" 2>/dev/null || stat -f '%Lp' "$secret_file")
  case "$permissions" in
    600 | 400) ;;
    *) fail "a deployment secret source does not have mode 0600 or 0400" ;;
  esac

  byte_count=$(wc -c < "$secret_file" | tr -d ' ')
  [ "$byte_count" -ge 20 ] || fail "a deployment secret is too short for reliable leak matching"

  for artifact in \
    "$temporary_dir/development-compose.yml" \
    "$temporary_dir/production-compose.yml" \
    "$temporary_dir/assistant.log" \
    "$temporary_dir/image-history" \
    "$temporary_dir/images.tar"
  do
    if grep -aFq -f "$secret_file" "$artifact"; then
      fail "a deployment secret appeared in $(basename "$artifact")"
    fi
  done

  if [ -n "${ASSISTANT_SECURITY_ARTIFACT_DIR:-}" ] &&
      [ -d "$ASSISTANT_SECURITY_ARTIFACT_DIR" ] &&
      grep -R -aFq -f "$secret_file" "$ASSISTANT_SECURITY_ARTIFACT_DIR"; then
    fail "a deployment secret appeared in release evidence or SBOM metadata"
  fi

  if git grep -q -F -f "$secret_file" -- . ':(exclude)secrets/**'; then
    fail "a deployment secret appeared in the working tree"
  fi

  for revision in $(git rev-list --all); do
    if git grep -q -F -f "$secret_file" "$revision" -- .; then
      fail "a current deployment secret appeared in Git history"
    fi
  done
done

# Trivy's filesystem scanner covers generated artifacts and image filesystems;
# it emits only redacted findings in CI through its configured output mode.
if ! command -v trivy >/dev/null 2>&1; then
  skip "Trivy is required for repository and image secret checks"
fi
if ! trivy fs --scanners secret --exit-code 1 --quiet --format json \
    --output "$temporary_dir/trivy-filesystem.json" \
    --skip-dirs "$repository_root/secrets" \
    --skip-dirs "$repository_root/assistant/testdata/adversarial" \
    --skip-files "$repository_root/web/test/fixtures/files/assistant_adversarial_contexts.yml" \
    "$repository_root"; then
  fail "Trivy found a secret outside the approved adversarial/source paths"
fi
if [ -n "${ASSISTANT_SECURITY_ARTIFACT_DIR:-}" ] && [ -d "$ASSISTANT_SECURITY_ARTIFACT_DIR" ]; then
  if ! trivy fs --scanners secret --exit-code 1 --quiet --format json \
      --output "$temporary_dir/trivy-artifacts.json" "$ASSISTANT_SECURITY_ARTIFACT_DIR"; then
    fail "Trivy found a secret in release evidence or SBOM metadata"
  fi
fi
while IFS= read -r image; do
  if ! trivy image --scanners secret --exit-code 1 --quiet --format json \
      --output "$temporary_dir/trivy-image.json" "$image"; then
    fail "Trivy found a secret in an Assistant image"
  fi
done < "$images_file"

echo "Assistant repository, history, config, log, and image secret checks passed."
