#!/usr/bin/env bash
set -euo pipefail
test "$(id -un)" = rbp || { echo 'run as rbp'; exit 1; }
release_source="${1:?release source directory required}"
test -x "$release_source/mynas"
test -f "$release_source/web/index.html"
test -f "$release_source/mynas.service"
test -f "$release_source/mynas.env"
findmnt -no SOURCE,FSTYPE,TARGET /mnt/nas | grep -q '^/dev/sda1 ntfs3 /mnt/nas$'
df -h /mnt/nas

mkdir -p /mnt/nas/.mynas/{staging,thumbnails,trash} "$HOME/.local/share/mynas"
chmod 700 /mnt/nas/.mynas "$HOME/.local/share/mynas"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
release_target="/opt/mynas/releases/$stamp"
sudo install -d -m 0755 "$release_target/web" /opt/mynas/releases
sudo install -m 0755 "$release_source/mynas" "$release_target/mynas"
sudo cp -a "$release_source/web/." "$release_target/web/"
sudo chown -R root:root "$release_target"
sudo install -D -m 0644 "$release_source/mynas.service" /etc/systemd/system/mynas.service
sudo install -D -m 0600 "$release_source/mynas.env" /etc/mynas/mynas.env
previous="$(readlink -f /opt/mynas/current 2>/dev/null || true)"
sudo ln -sfn "$release_target" /opt/mynas/current
printf '%s\n' "$previous" | sudo tee "$release_target/previous-release" >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable mynas
sudo systemctl restart mynas
systemctl is-active --quiet mynas
echo "release=$release_target"
echo "previous=$previous"
