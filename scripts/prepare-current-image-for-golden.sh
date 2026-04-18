#!/usr/bin/env bash
set -euo pipefail

# Prepare an existing Ubuntu VM to become a generic golden image for Hyper-V.
# Run this INSIDE the current Ubuntu VM, before sealing it.
#
# What this script does:
#   - installs and enables cloud-init + openssh if missing
#   - enables predictable NoCloud datasource discovery
#   - removes local "cloud-init disabled" flags if present
#   - backs up old static netplan and replaces it with a generic DHCP config
#   - locks the existing admin password and removes stale authorized_keys
#   - disables SSH password authentication for future clones
#   - leaves the VM ready for final sealing
#
# What this script does NOT do:
#   - it does not power off the VM
#   - it does not destroy your old config without backup
#   - it does not install project-specific tooling

PRIMARY_USER="${PRIMARY_USER:-ubuntuadmin}"
TEMPLATE_HOSTNAME="${TEMPLATE_HOSTNAME:-ubuntu-template}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/golden-image-prep-$(date +%Y%m%d-%H%M%S)}"
APT_PACKAGES=(
  bash-completion
  ca-certificates
  cloud-init
  curl
  git
  htop
  jq
  openssh-server
  qemu-guest-agent
  rsync
  sudo
  tmux
)

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

mkdir -p "$BACKUP_ROOT"/{cloud-cfg,netplan,ssh,home}

echo "[1/8] Installing required base packages ..."
apt-get update
apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"


echo "[2/8] Re-enabling cloud-init if it had been disabled ..."
rm -f /etc/cloud/cloud-init.disabled
mkdir -p /etc/cloud/cloud.cfg.d

# Some ISO-installed Ubuntu systems or manual tweaks may leave files that disable
# cloud-init networking. Move those aside so NoCloud network-config can work.
shopt -s nullglob
for cfg in /etc/cloud/cloud.cfg.d/*.cfg; do
  if grep -Eq 'network:\s*\{\s*config:\s*disabled\s*\}' "$cfg"; then
    mv "$cfg" "$BACKUP_ROOT/cloud-cfg/$(basename "$cfg")"
  fi
done
shopt -u nullglob

# Restrict datasource lookup to NoCloud for predictable local clones.
cat > /etc/cloud/cloud.cfg.d/99-generic-nocloud.cfg <<'CLOUDCFG'
datasource_list: [ NoCloud, None ]
CLOUDCFG

# Keep future clones free to accept hostname from cloud-init seed data.
cat > /etc/cloud/cloud.cfg.d/98-golden-base.cfg <<'GOLDENCFG'
preserve_hostname: false
manage_etc_hosts: true
GOLDENCFG


echo "[3/8] Backing up existing netplan and writing a generic DHCP profile ..."
if [[ -d /etc/netplan ]]; then
  find /etc/netplan -maxdepth 1 -type f -name '*.yaml' -exec mv {} "$BACKUP_ROOT/netplan/" \;
fi

mkdir -p /etc/netplan
cat > /etc/netplan/01-golden-dhcp.yaml <<'NETPLAN'
network:
  version: 2
  ethernets:
    default:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: false
      optional: true
NETPLAN
chmod 600 /etc/netplan/01-golden-dhcp.yaml
netplan generate


echo "[4/8] Resetting the image hostname to a generic value ..."
printf '%s\n' "$TEMPLATE_HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$TEMPLATE_HOSTNAME" || true


echo "[5/8] Locking local password-based access for the existing admin account ..."
if id -u "$PRIMARY_USER" >/dev/null 2>&1; then
  passwd -l "$PRIMARY_USER" || true
  user_home="$(getent passwd "$PRIMARY_USER" | cut -d: -f6)"
  if [[ -n "$user_home" && -d "$user_home" ]]; then
    mkdir -p "$BACKUP_ROOT/home/$PRIMARY_USER"
    if [[ -f "$user_home/.ssh/authorized_keys" ]]; then
      mv "$user_home/.ssh/authorized_keys" "$BACKUP_ROOT/home/$PRIMARY_USER/authorized_keys"
    fi
  fi
fi


echo "[6/8] Disabling SSH password authentication for future clones ..."
mkdir -p /etc/ssh/sshd_config.d
if [[ -f /etc/ssh/sshd_config ]]; then
  cp -a /etc/ssh/sshd_config "$BACKUP_ROOT/ssh/sshd_config"
fi
if [[ -d /etc/ssh/sshd_config.d ]]; then
  cp -a /etc/ssh/sshd_config.d "$BACKUP_ROOT/ssh/sshd_config.d" || true
fi
cat > /etc/ssh/sshd_config.d/99-golden-base.conf <<'SSHCFG'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
UsePAM yes
SSHCFG


echo "[7/8] Enabling cloud-init and guest services ..."
systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service ssh.service || true
systemctl enable qemu-guest-agent.service || true


echo "[8/8] Creating a quick validation helper ..."
cat > /usr/local/bin/golden-image-check <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
printf 'cloud-init: '; cloud-init --version
printf 'hostname: '; hostnamectl --static || hostname
printf 'sshd syntax: '; sshd -t && echo ok
printf 'datasource_list: '; grep -R "datasource_list" /etc/cloud/cloud.cfg.d || true
printf 'netplan files:\n'; ls -1 /etc/netplan/*.yaml
CHECK
chmod +x /usr/local/bin/golden-image-check


echo
echo "Preparation completed."
echo "Backups are in: $BACKUP_ROOT"
echo "Next recommended steps:"
echo "  1) Reboot once and verify networking still works (it should now be DHCP-based)."
echo "  2) Run: golden-image-check"
echo "  3) When satisfied, run scripts/seal-golden-image.sh"
