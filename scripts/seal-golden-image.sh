#!/usr/bin/env bash
set -euo pipefail

# Final cleanup before powering off the VM and storing its VHDX as a golden image.
# Run this INSIDE the Ubuntu VM after prepare-current-image-for-golden.sh.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

sync

# Remove the source-machine backup created by the preparation script. Refuse
# unknown paths instead of recursively deleting a user-supplied location.
PREP_STATE_DIR="/var/lib/golden-image-prep"
PREP_BACKUP_RECORD="$PREP_STATE_DIR/backup-root"
if [[ -f "$PREP_BACKUP_RECORD" ]]; then
  prep_backup="$(<"$PREP_BACKUP_RECORD")"
  if [[ -e "$prep_backup" ]]; then
    prep_backup="$(readlink -f "$prep_backup")"
    case "$prep_backup" in
      /var/backups/golden-image-prep-*)
        rm -rf -- "$prep_backup"
        ;;
      *)
        echo "Refusing to remove unexpected preparation backup: $prep_backup" >&2
        echo "Move or remove it explicitly before sealing the image." >&2
        exit 1
        ;;
    esac
  fi
  rm -f -- "$PREP_BACKUP_RECORD"
fi
rmdir "$PREP_STATE_DIR" 2>/dev/null || true

# Remove host-specific identity.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*

# Remove user-specific leftovers.
rm -f /root/.bash_history
find /home -maxdepth 2 -type f -name '.bash_history' -delete || true
find /home -maxdepth 3 -type f -path '*/.ssh/authorized_keys' -delete || true

# Remove transient logs and package cache.
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*

# Reset cloud-init so next boot behaves like first boot.
cloud-init clean --logs --machine-id --configs all --seed

sync

echo
echo "Golden image sealing completed."
echo "Now shut down the VM and keep the VHDX as the generic golden image."
