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
