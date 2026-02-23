#!/usr/bin/env bash
# setup-smb-shares.sh
# Run on each server (sullivan and freddy) as root or with sudo
# Usage: sudo bash setup-smb-shares.sh

set -euo pipefail

HOSTNAME=$(hostname -s)
SMB_USER="jordan"
SMB_GROUP="actions"

echo "=== Setting up Samba on ${HOSTNAME} ==="

# ─────────────────────────────────────────────
# 1. Install Samba
# ─────────────────────────────────────────────
echo "[1/7] Installing Samba..."
apt update -qq
apt install -y samba samba-common-bin

# ─────────────────────────────────────────────
# 2. Create samba user (maps to existing jordan)
# ─────────────────────────────────────────────
echo "[2/7] Creating Samba user '${SMB_USER}'..."
echo "  You'll be prompted to set the SMB password."
smbpasswd -a "${SMB_USER}"
smbpasswd -e "${SMB_USER}"

# ─────────────────────────────────────────────
# 3. Ensure jordan is in the actions group
# ─────────────────────────────────────────────
echo "[3/7] Adding ${SMB_USER} to ${SMB_GROUP} group..."
usermod -aG "${SMB_GROUP}" "${SMB_USER}"

# ─────────────────────────────────────────────
# 4. Configure AppArmor for Samba share paths
# ─────────────────────────────────────────────
echo "[4/7] Configuring AppArmor for Samba..."
mkdir -p /etc/apparmor.d/samba

if [[ "${HOSTNAME}" == "sullivan" ]]; then
    cat > /etc/apparmor.d/samba/smbd-shares << 'EOF'
/media/ r,
/media/** lrwk,
/mnt/media/ r,
/mnt/media/** lrwk,
EOF

elif [[ "${HOSTNAME}" == "freddy" ]]; then
    cat > /etc/apparmor.d/samba/smbd-shares << 'EOF'
/media/ r,
/media/** lrwk,
/mnt/1tb/ r,
/mnt/1tb/** lrwk,
EOF
fi

# Reload AppArmor if active
if systemctl is-active --quiet apparmor; then
    systemctl reload apparmor
    echo "  AppArmor reloaded with Samba share paths."
else
    echo "  AppArmor not active, skipping reload."
fi

# ─────────────────────────────────────────────
# 5. Fix directory permissions (background for large dirs)
# ─────────────────────────────────────────────
echo "[5/7] Setting permissions (runs in background for large directories)..."

if [[ "${HOSTNAME}" == "sullivan" ]]; then
    SHARE_DIRS=("/media" "/mnt/media")
elif [[ "${HOSTNAME}" == "freddy" ]]; then
    SHARE_DIRS=("/media" "/mnt/1tb")
else
    SHARE_DIRS=()
    echo "  Unknown hostname '${HOSTNAME}'. Set permissions manually."
fi

for dir in "${SHARE_DIRS[@]}"; do
    if [[ -d "${dir}" ]]; then
        echo "  Fixing ${dir} in background..."
        nohup bash -c "
            chown -R actions:actions '${dir}' && \
            find '${dir}' -type d -exec chmod 2775 {} \; && \
            find '${dir}' -type f -exec chmod 664 {} \; && \
            echo '${dir} permissions complete' >> /tmp/perms-fix.log
        " >> /tmp/perms-fix.log 2>&1 &
    else
        echo "  WARNING: ${dir} does not exist, skipping."
    fi
done
echo "  Monitor progress: tail -f /tmp/perms-fix.log"

# ─────────────────────────────────────────────
# 6. Configure Samba
# ─────────────────────────────────────────────
echo "[6/7] Writing Samba configuration..."

# Backup existing config
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%Y%m%d%H%M%S)

if [[ "${HOSTNAME}" == "sullivan" ]]; then
    cat > /etc/samba/smb.conf << 'EOF'
[global]
    workgroup = WORKGROUP
    server string = Sullivan Media Server
    server role = standalone server
    security = user
    map to guest = never
    log file = /var/log/samba/log.%m
    max log size = 1000
    logging = file

    # Performance tuning
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
    read raw = yes
    write raw = yes
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384

    # Permissions - new files/dirs inherit group ownership
    create mask = 0664
    directory mask = 2775
    force group = actions

    # macOS compatibility
    vfs objects = catia fruit streams_xattr
    fruit:metadata = stream
    fruit:model = MacSamba
    fruit:posix_rename = yes
    fruit:veto_appledouble = no
    fruit:nfs_aces = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles = yes

[media]
    comment = Sullivan Media Root (/mnt/media)
    path = /mnt/media
    browseable = yes
    read only = no
    valid users = jordan
    force user = actions
    force group = actions
    create mask = 0664
    directory mask = 2775
    inherit permissions = yes

[local-media]
    comment = Sullivan Local Media (/media)
    path = /media
    browseable = yes
    read only = no
    valid users = jordan
    force user = actions
    force group = actions
    create mask = 0664
    directory mask = 2775
    inherit permissions = yes
EOF

elif [[ "${HOSTNAME}" == "freddy" ]]; then
    cat > /etc/samba/smb.conf << 'EOF'
[global]
    workgroup = WORKGROUP
    server string = Freddy Personal Server
    server role = standalone server
    security = user
    map to guest = never
    log file = /var/log/samba/log.%m
    max log size = 1000
    logging = file

    # Performance tuning
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
    read raw = yes
    write raw = yes
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384

    # Permissions - new files/dirs inherit group ownership
    create mask = 0664
    directory mask = 2775
    force group = actions

    # macOS compatibility
    vfs objects = catia fruit streams_xattr
    fruit:metadata = stream
    fruit:model = MacSamba
    fruit:posix_rename = yes
    fruit:veto_appledouble = no
    fruit:nfs_aces = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles = yes

[storage]
    comment = Freddy 1TB Storage (/mnt/1tb)
    path = /mnt/1tb
    browseable = yes
    read only = no
    valid users = jordan
    force user = actions
    force group = actions
    create mask = 0664
    directory mask = 2775
    inherit permissions = yes

[local-media]
    comment = Freddy Local Media (/media)
    path = /media
    browseable = yes
    read only = no
    valid users = jordan
    force user = actions
    force group = actions
    create mask = 0664
    directory mask = 2775
    inherit permissions = yes
EOF
fi

# ─────────────────────────────────────────────
# 7. Validate, enable, and start
# ─────────────────────────────────────────────
echo "[7/7] Starting Samba..."
echo ""
echo "=== Validating config ==="
testparm -s

echo ""
echo "=== Enabling and restarting Samba ==="
systemctl enable smbd nmbd
systemctl restart smbd nmbd

# Firewall (if ufw is active)
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    echo "=== Adding UFW rules for Samba ==="
    ufw allow samba
    echo "  Samba allowed through firewall."
else
    echo "=== UFW not active, skipping firewall config ==="
    echo "  If using another firewall, open TCP 139,445 and UDP 137,138."
fi

echo ""
echo "=== Done! ==="
echo "Shares available on ${HOSTNAME}:"
smbclient -L localhost -U "${SMB_USER}" -N 2>/dev/null || echo "  (run 'smbclient -L localhost -U jordan' to verify)"
echo ""
echo "Key details:"
echo "  - SMB user: jordan"
echo "  - All files forced to actions:actions ownership"
echo "  - setgid bit (2775) ensures new dirs inherit group"
echo "  - Docker containers (uid 1001/actions) retain full access"
echo "  - AppArmor configured for share paths"
echo "  - Permission fix running in background (tail -f /tmp/perms-fix.log)"
