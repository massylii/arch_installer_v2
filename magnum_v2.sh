#!/usr/bin/env bash
# Magnum Secure Installer (Btrfs + LUKS2 + Secure Boot)
# WARNING: This will wipe the target disk entirely

set -euo pipefail
shopt -s nullglob

DISK="/dev/sda"        # Target disk (change if needed)
HOSTNAME="archsecure"  # Hostname
USER="alice"           # Username
EFI_SIZE="1G"          # EFI partition size
PACKAGES="base linux linux-firmware btrfs-progs vim sudo networkmanager ufw fail2ban audit" # Base + security

# -----------------------------
# Prompt for passwords
# -----------------------------
read -sp "Set LUKS passphrase: " LUKS_PASS
echo
read -sp "Set root password: " ROOT_PASS
echo
read -sp "Set ${USER} password: " USER_PASS
echo

# -----------------------------
# Partition disk
# -----------------------------
echo "[+] Partitioning disk..."
parted --script "$DISK" \
  mklabel gpt \
  mkpart ESP fat32 1MiB "$EFI_SIZE" \
  set 1 boot on \
  mkpart primary "$EFI_SIZE" 100%

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"

# -----------------------------
# Format partitions and setup LUKS2
# -----------------------------
echo "[+] Formatting EFI partition..."
mkfs.fat -F32 "$EFI_PART"

echo "[+] Setting up LUKS2 on root..."
echo "$LUKS_PASS" | cryptsetup luksFormat "$ROOT_PART" \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --hash sha512 \
  --iter-time 5000 \
  --key-size 512 \
  --pbkdf argon2id \
  --use-urandom \
  --verify-passphrase -

echo "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -

# -----------------------------
# Setup Btrfs with subvolumes
# -----------------------------
echo "[+] Creating Btrfs filesystem..."
mkfs.btrfs /dev/mapper/cryptroot

echo "[+] Creating subvolumes..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@snapshots
umount /mnt

echo "[+] Mounting subvolumes..."
mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var,tmp,.snapshots,boot/efi}
mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,subvol=@var /dev/mapper/cryptroot /mnt/var
mount -o noatime,compress=zstd,subvol=@tmp /dev/mapper/cryptroot /mnt/tmp
mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount "$EFI_PART" /mnt/boot/efi

# -----------------------------
# Install base system
# -----------------------------
echo "[+] Installing base system..."
pacstrap /mnt $PACKAGES

# -----------------------------
# Generate fstab
# -----------------------------
echo "[+] Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------
# Chroot and configure system
# -----------------------------
arch-chroot /mnt /bin/bash <<EOF
set -e

echo "[+] Setting hostname..."
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

echo "[+] Setting root password..."
echo "root:$ROOT_PASS" | chpasswd

echo "[+] Creating user..."
useradd -mG wheel,audio,video,optical,network -s /bin/bash $USER
echo "$USER:$USER_PASS" | chpasswd

echo "[+] Configuring sudoers..."
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "[+] Enabling essential services..."
systemctl enable NetworkManager
systemctl enable ufw
ufw enable
systemctl enable auditd
systemctl enable fail2ban

# -----------------------------
# System hardening
# -----------------------------
echo "[+] Applying sysctl hardening..."
cat > /etc/sysctl.d/99-secure.conf <<SYSCTL
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
SYSCTL
sysctl --system

# -----------------------------
# Setup systemd-boot & Secure Boot
# -----------------------------
echo "[+] Installing systemd-boot..."
bootctl --path=/boot/efi install

# Generate keys for Secure Boot
mkdir -p /boot/efi/keys
openssl req -new -x509 -newkey rsa:4096 -subj "/CN=Arch Secure Boot/" -keyout /boot/efi/keys/db.key -out /boot/efi/keys/db.crt -nodes -days 3650

# Sign the bootloader and kernel
sbsign --key /boot/efi/keys/db.key --cert /boot/efi/keys/db.crt /boot/vmlinuz-linux --output /boot/vmlinuz-linux.signed

# Create loader entry
cat > /boot/efi/loader/loader.conf <<LOADER
default arch
timeout 3
editor 0
LOADER

mkdir -p /boot/efi/loader/entries
cat > /boot/efi/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux.signed
initrd  /initramfs-linux.img
options cryptdevice=UUID=$(blkid -s UUID -o value $ROOT_PART):cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@
ENTRY

EOF

# -----------------------------
# Finish
# -----------------------------
echo "[+] Installation complete! Rebooting..."
umount -R /mnt
cryptsetup close cryptroot
reboot
