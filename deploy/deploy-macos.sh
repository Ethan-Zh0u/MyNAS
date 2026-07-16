#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
remote=${MYNAS_REMOTE:-rbp@rsp}
key=${MYNAS_DEPLOY_KEY:-$HOME/.ssh/mynas_deploy}
pages_origin=${MYNAS_PAGES_ORIGIN:-https://mynas-rsp.pages.dev}
private_origin=${MYNAS_PRIVATE_ORIGIN:-https://rsp.tail681937.ts.net}
version=$(tr -d '[:space:]' < "$root/VERSION")
stamp=$(date -u +%Y%m%dT%H%M%SZ)
remote_release="/tmp/mynas-release-$stamp"
build_dir="$root/.dev-state/deploy-$stamp"
archive="$build_dir/frontend-dist.tar"
env_file="$build_dir/mynas.env"

ssh_options=(
  -i "$key"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
  -o ProxyCommand=none
  -o ProxyJump=none
)

cleanup() {
  rm -rf "$build_dir"
}
trap cleanup EXIT

retry() {
  local label=$1
  shift
  local attempt
  for attempt in 1 2 3; do
    if "$@"; then return 0; fi
    if [ "$attempt" -lt 3 ]; then
      echo "$label failed ($attempt/3); retrying..." >&2
      sleep $((attempt * 2))
    fi
  done
  echo "$label failed after 3 attempts." >&2
  return 1
}

for command in go pnpm ssh scp tar curl; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

case "$pages_origin" in https://*) ;; *) echo "MYNAS_PAGES_ORIGIN must be an HTTPS URL." >&2; exit 1 ;; esac
case "$private_origin" in https://*) ;; *) echo "MYNAS_PRIVATE_ORIGIN must be an HTTPS URL." >&2; exit 1 ;; esac
test -f "$key" || { echo "Missing deployment key: $key" >&2; exit 1; }
mkdir -p "$build_dir"

echo "Building and testing MyNAS v$version..."
(
  cd "$root/frontend"
  pnpm install --frozen-lockfile
  pnpm test
  VITE_API_URL="$private_origin" pnpm build
)
(
  cd "$root/backend"
  GOCACHE="$build_dir/go-build" go test ./...
  GOCACHE="$build_dir/go-build" go vet ./...
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOCACHE="$build_dir/go-build" \
    go build -buildvcs=false -trimpath -ldflags='-s -w' -o "$build_dir/mynas" .
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOCACHE="$build_dir/go-build" \
    go build -buildvcs=false -trimpath -ldflags='-s -w' -o "$build_dir/mynas-setup" ./cmd/mynas-setup
)
COPYFILE_DISABLE=1 tar -cf "$archive" -C "$root/frontend/dist" .
printf 'MYNAS_ALLOWED_ORIGIN=%s\nMYNAS_PRIVATE_ORIGIN=%s\n' "$pages_origin" "$private_origin" > "$env_file"

echo "Checking $remote before deployment..."
retry "remote preflight" ssh "${ssh_options[@]}" "$remote" \
  "set -eu; sudo -n true; findmnt -no SOURCE,FSTYPE,TARGET /mnt/nas; df -h /mnt/nas; systemctl is-active --quiet smbd; mkdir -p '$remote_release/web'"

echo "Uploading release files..."
retry "backend upload" scp "${ssh_options[@]}" "$build_dir/mynas" "$remote:$remote_release/mynas"
retry "setup wizard upload" scp "${ssh_options[@]}" "$build_dir/mynas-setup" "$remote:$remote_release/mynas-setup"
retry "deployment files upload" scp "${ssh_options[@]}" \
  "$root/deploy/mynas.service" "$root/deploy/install-pi.sh" "$remote:$remote_release/"
retry "frontend upload" scp "${ssh_options[@]}" "$archive" "$remote:$remote_release/frontend-dist.tar"
retry "environment upload" scp "${ssh_options[@]}" "$env_file" "$remote:$remote_release/mynas.env"

echo "Installing release atomically..."
ssh "${ssh_options[@]}" "$remote" \
  "set -eu; tar -xf '$remote_release/frontend-dist.tar' -C '$remote_release/web'; test -f '$remote_release/web/index.html'; chmod +x '$remote_release/mynas' '$remote_release/mynas-setup' '$remote_release/install-pi.sh'; bash '$remote_release/install-pi.sh' '$remote_release'; sudo tailscale serve --bg --yes 127.0.0.1:8080"

echo "Verifying the deployed service..."
retry "remote validation" ssh "${ssh_options[@]}" "$remote" \
  "set -eu; systemctl is-active --quiet mynas; response=\$(curl --fail --silent -H 'Tailscale-User-Login: deploy-check' -H 'Tailscale-User-Name: deploy-check' http://127.0.0.1:8080/api/v1/health); printf '%s\n' \"\$response\"; printf '%s' \"\$response\" | grep -F '\"version\":\"$version\"' >/dev/null; printf 'current='; readlink -f /opt/mynas/current; tailscale serve status"

echo "MyNAS v$version deployed successfully to $remote."
echo "Release source: $remote_release"
