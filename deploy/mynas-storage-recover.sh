#!/usr/bin/env bash
set -u

mount_path=/mnt/nas

log() {
  logger -t mynas-storage-recover -- "$*" || true
  printf '%s\n' "$*"
}

if mountpoint -q "$mount_path"; then
  systemctl reset-failed mynas.service || true
  systemctl start mynas.service || true
  exit 0
fi

mkdir -p "$mount_path"
if ! mount "$mount_path"; then
  log "NAS volume is not mounted; automatic mount retry failed"
  exit 1
fi

if ! mountpoint -q "$mount_path"; then
  log "mount returned success but $mount_path is not a mount point"
  exit 1
fi

log "NAS volume mounted; starting MyNAS"
systemctl reset-failed mynas.service || true
systemctl start mynas.service
