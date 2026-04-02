#!/usr/bin/env bash
# =============================================================================
# Arch Linux Installer — MacBook Pro 11,1 (BCM4360 + Btrfs)
# Phase 1: Run from Arch Linux Live CD
# Usage: bash install.sh
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' C='\033[0;36m' NC='\033[0m'
info()    { echo -e "${B}[INFO]${NC}  $*"; }
success() { echo -e "${G}[OK]${NC}    $*"; }
warn()    { echo -e "${Y}[WARN]${NC}  $*"; }
error()   { echo -e "${R}[ERR]${NC}   $*"; exit 1; }
header()  { echo -e "\n${C}━━━  $*  ━━━${NC}\n"; }

# ── Config — edit these before running ────────────────────────────────────────
DISK="/dev/sda"
HOSTNAME="macbook"
USERNAME="jordan"
TIMEZONE="America/Toronto"          # London, Ontario
LOCALE="en_CA.UTF-8"
KEYMAP="us"

# Btrfs subvolume layout
SUBVOLS=("@" "@home" "@var" "@log" "@pkg" "@snapshots")

# Btrfs mount options (optimised for Apple SSD)
BTRFS_OPTS="noatime,compress=zstd:1,discard=async,space_cache=v2,autodefrag"

# ── Sanity checks ─────────────────────────────────────────────────────────────
header "Pre-flight checks"

[[ $EUID -ne 0 ]] && error "Run as root (you're on the live CD, just use sudo bash install.sh)"
ping -c1 -W3 archlinux.org &>/dev/null || error "No internet. Plug in USB ethernet or iPhone USB tethering first."
[[ -b "$DISK" ]] || error "Disk $DISK not found. Check lsblk."

success "Disk: $DISK"
success "Internet: OK"

# ── Confirm wipe ──────────────────────────────────────────────────────────────
echo ""
warn "This will WIPE $DISK completely."
lsblk "$DISK"
echo ""
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || error "Aborted."

# ── Password setup ────────────────────────────────────────────────────────────
header "Set passwords"
read -rsp "Root password: "       ROOT_PASS; echo
read -rsp "Password for $USERNAME: " USER_PASS; echo

# ── Clock ─────────────────────────────────────────────────────────────────────
header "Sync clock"
timedatectl set-ntp true
success "NTP enabled"

# ── Partitioning ──────────────────────────────────────────────────────────────
header "Partitioning $DISK"

# 512 MiB EFI + rest Btrfs
parted -s "$DISK" \
  mklabel gpt \
  mkpart ESP  fat32   1MiB  513MiB \
  set 1 esp on \
  mkpart root btrfs 513MiB 100%

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"

# Small delay for kernel to see new partitions
sleep 1
partprobe "$DISK"

success "Partitioned: $EFI_PART (EFI), $ROOT_PART (Btrfs)"

# ── Format ────────────────────────────────────────────────────────────────────
header "Formatting"

mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.btrfs -f -L archlinux "$ROOT_PART"

success "Formatted $EFI_PART as FAT32, $ROOT_PART as Btrfs"

# ── Btrfs subvolumes ──────────────────────────────────────────────────────────
header "Creating Btrfs subvolumes"

mount "$ROOT_PART" /mnt

for sv in "${SUBVOLS[@]}"; do
  btrfs subvolume create "/mnt/$sv"
  success "Created subvolume: $sv"
done

umount /mnt

# ── Mount everything ──────────────────────────────────────────────────────────
header "Mounting filesystems"

# Root (@)
mount -o "$BTRFS_OPTS,subvol=@"          "$ROOT_PART" /mnt

# Create mount points
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}

mount -o "$BTRFS_OPTS,subvol=@home"      "$ROOT_PART" /mnt/home
mount -o "$BTRFS_OPTS,subvol=@log"       "$ROOT_PART" /mnt/var/log
mount -o "$BTRFS_OPTS,subvol=@pkg"       "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount -o "$BTRFS_OPTS,subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots
mount "$EFI_PART" /mnt/boot/efi

success "All filesystems mounted"

# ── Base install ──────────────────────────────────────────────────────────────
header "Installing base system (pacstrap)"

BASE_PKGS=(
  # Core
  base base-devel linux linux-headers linux-firmware
  # Boot
  grub efibootmgr
  # Btrfs
  btrfs-progs
  # Networking
  networkmanager iwd dhcpcd openssh
  # System essentials
  sudo git curl wget reflector
  # Text editors (minimal, Zed installed later)
  vim nano
  # Terminal utils
  htop btop tree fd ripgrep bat eza fzf
  # Shells
  zsh zsh-completions
  # Build tools (needed for AUR)
  cmake ninja meson
  # Python (system)
  python python-pip python-pipx
  # Go
  go
  # Node.js + npm
  nodejs npm
  # .NET SDK
  dotnet-sdk
  # Rust (via rustup — manages toolchains properly)
  rustup
  # Font support (for Zed)
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji
  # Apple SSD / power
  thermald tlp
  # Sensors
  lm_sensors
  # Man pages
  man-db man-pages
  # dkms (required for broadcom-wl)
  dkms
)

pacstrap -K /mnt "${BASE_PKGS[@]}"
success "Base system installed"

# ── fstab ─────────────────────────────────────────────────────────────────────
header "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab
success "fstab written"

# ── Chroot configuration ───────────────────────────────────────────────────────
header "Entering chroot for system configuration"

arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail

# Timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale
echo "${LOCALE} UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8"    >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Keymap
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# ── mkinitcpio (add btrfs) ────────────────────────────────────────────────────
sed -i 's/^MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
mkinitcpio -P

# ── GRUB for EFI (Mac) ────────────────────────────────────────────────────────
# Apple needs --removable flag so GRUB is found at boot
grub-install --target=x86_64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id=GRUB \
             --removable

# Enable quiet boot, keep splash off for now
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"/' \
    /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg

# ── Passwords ─────────────────────────────────────────────────────────────────
echo "root:${ROOT_PASS}" | chpasswd

useradd -m -G wheel,audio,video,optical,storage,docker -s /bin/zsh "${USERNAME}"
echo "${USERNAME}:${USER_PASS}" | chpasswd

# sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ── Services ──────────────────────────────────────────────────────────────────
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable thermald
systemctl enable tlp
systemctl enable fstrim.timer      # Weekly TRIM for SSD

# ── SSH hardening (still usable) ─────────────────────────────────────────────
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/'    /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# ── Broadcom BCM4360 driver (wl) via AUR ─────────────────────────────────────
# Install yay as the user, then broadcom-wl-dkms
# This is done inside chroot as the non-root user

# Temporarily allow passwordless sudo for AUR build
echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/aur_temp

su - "${USERNAME}" -c '
  cd /tmp
  git clone https://aur.archlinux.org/yay.git
  cd yay
  makepkg -si --noconfirm
  cd /tmp && rm -rf yay

  # Broadcom WL driver
  yay -S --noconfirm broadcom-wl-dkms

  # Zed IDE (from AUR)
  yay -S --noconfirm zed

  # Android SDK tools (command-line tools via AUR)
  yay -S --noconfirm android-sdk android-sdk-platform-tools android-sdk-build-tools
'

# Remove temp sudo rule
rm /etc/sudoers.d/aur_temp

# ── Blacklist conflicting Broadcom modules ────────────────────────────────────
cat > /etc/modprobe.d/broadcom-wl.conf <<MOD
blacklist b43
blacklist b43legacy
blacklist bcm43xx
blacklist brcm80211
blacklist brcmfmac
blacklist brcmsmac
blacklist ssb
MOD

# Load wl at boot
echo "wl" > /etc/modules-load.d/broadcom-wl.conf

# ── Rust default toolchain ────────────────────────────────────────────────────
su - "${USERNAME}" -c 'rustup default stable && rustup component add rust-analyzer clippy rustfmt'

# ── Android SDK environment ───────────────────────────────────────────────────
cat >> /home/${USERNAME}/.zshrc <<'ENV'

# Android SDK
export ANDROID_HOME=/opt/android-sdk
export PATH=\$PATH:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/tools:\$ANDROID_HOME/cmdline-tools/latest/bin

# Go
export GOPATH=\$HOME/go
export PATH=\$PATH:\$GOPATH/bin

# Rust
export PATH=\$PATH:\$HOME/.cargo/bin

# dotnet telemetry opt-out
export DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV

chown "${USERNAME}:${USERNAME}" /home/${USERNAME}/.zshrc

CHROOT

success "Chroot configuration complete"

# ── Done ──────────────────────────────────────────────────────────────────────
header "Installation complete!"
echo ""
echo -e "  ${G}Next steps:${NC}"
echo -e "  1. ${Y}umount -R /mnt${NC}"
echo -e "  2. ${Y}reboot${NC}"
echo -e "  3. Remove live USB when screen goes dark"
echo -e "  4. WiFi (BCM4360) will work after boot"
echo -e "  5. Run ${Y}post-install.sh${NC} as ${USERNAME} after first login"
echo ""

