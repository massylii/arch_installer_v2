#!/usr/bin/env bash
# magnum_full_secure_install.sh
# Full single-script Arch installer:
# LUKS2 -> Btrfs (subvols: @, @home, @var, @snapshots, @tmp)
# systemd-boot + sbctl for Secure Boot, plus kernel-signing pacman hook
#
set -euo pipefail
trap 'echo "ERROR on line $LINENO"; exit 1' ERR

# ---------------- CONFIG (EDIT BEFORE RUNNING) ----------------
DISK="/dev/sda"        # <<< CHANGE THIS to your target disk (e.g. /dev/sda or /dev/nvme0n1)
EFI_SIZE="1024MiB"
CRYPT_NAME="cryptroot"
BTRFS_LABEL="ARCHCRYPT"
HOSTNAME="arch-secure"
USERNAME="massylii"
TIMEZONE="Africa/Algiers"
LOCALE="en_US.UTF-8"
KEYMAP="us"
# packages to install in base system
PKGS="base linux linux-headers linux-firmware btrfs-progs sbctl sbsigntools dosfstools \
efibootmgr networkmanager vim sudo openssh"
# ----------------------------------------------------------------

# helper for nvme partition names
part() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ nvme ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root from an Arch live ISO."
  exit 1
fi

echo "Target disk: $DISK"
read -rp "THIS WILL DESTROY ALL DATA ON $DISK. Type EXACTLY 'I UNDERSTAND' to continue: " conf
if [ "$conf" != "I UNDERSTAND" ]; then
  echo "Aborted."
  exit 1
fi

# Prompt for passwords (will be used for root + user)
read -rp "Username to create (default: $USERNAME): " tmpu
[ -n "$tmpu" ] && USERNAME="$tmpu"
echo "Enter password for root (you'll confirm):"
passwd_root() {
  read -s -p "Root password: " r1; echo
  read -s -p "Confirm root password: " r2; echo
  [ "$r1" = "$r2" ] || { echo "Mismatch, try again"; passwd_root; return; }
  ROOT_PW="$r1"
}
passwd_root

echo "Enter password for user '$USERNAME' (you'll confirm):"
passwd_user() {
  read -s -p "User password: " u1; echo
  read -s -p "Confirm user password: " u2; echo
  [ "$u1" = "$u2" ] || { echo "Mismatch, try again"; passwd_user; return; }
  USER_PW="$u1"
}
passwd_user

# Partitioning
echo "Wiping partition table..."
sgdisk --zap-all "$DISK"

echo "Creating partitions..."
parted --script "$DISK" \
  mklabel gpt \
  mkpart ESP fat32 1MiB ${EFI_SIZE} \
  set 1 boot on \
  mkpart primary ${EFI_SIZE} 100%

EFI_PART="$(part "$DISK" 1)"
LUKS_PART="$(part "$DISK" 2)"
echo "EFI: $EFI_PART"
echo "LUKS: $LUKS_PART"

# Wait for device nodes
sleep 1
partprobe "$DISK" || true

# Format EFI
echo "Formatting EFI partition..."
mkfs.fat -F32 -n EFI "$EFI_PART"

# Setup LUKS2 (interactive passphrase)
echo "Initializing LUKS2 on $LUKS_PART (you will be prompted for a passphrase)..."
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --hash sha512 --iter-time 5000 --key-size 512 --pbkdf argon2id --use-urandom --verify-passphrase "$LUKS_PART"
cryptsetup open "$LUKS_PART" "$CRYPT_NAME"

CRYPT_DEV="/dev/mapper/${CRYPT_NAME}"

# Create Btrfs and subvolumes
echo "Creating Btrfs on $CRYPT_DEV..."
mkfs.btrfs -L "$BTRFS_LABEL" "$CRYPT_DEV"

echo "Creating subvolumes..."
mount "$CRYPT_DEV" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@tmp
umount /mnt

# Mount subvolumes with recommended options
MOUNT_OPTS="noatime,ssd,space_cache=v2,compress=zstd:1,autodefrag,discard=async,subvol="
echo "Mounting root (@) to /mnt"
mount -o ${MOUNT_OPTS}@ "$CRYPT_DEV" /mnt
mkdir -p /mnt/{home,var,.snapshots,tmp,boot/efi}

mount -o ${MOUNT_OPTS}@home "$CRYPT_DEV" /mnt/home
mount -o ${MOUNT_OPTS}@var "$CRYPT_DEV" /mnt/var
mount -o ${MOUNT_OPTS}@snapshots "$CRYPT_DEV" /mnt/.snapshots
# /tmp with hardened mount options
mount -o noatime,ssd,space_cache=v2,compress=zstd:1,autodefrag,discard=async,noexec,nosuid,nodev,subvol=@tmp "$CRYPT_DEV" /mnt/tmp

# Mount EFI
mount "$EFI_PART" /mnt/boot/efi

# Install base system
echo "Installing base packages: $PKGS"
pacstrap /mnt $PKGS

# Generate fstab
echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Write a comprehensive chroot script to finalize config
cat > /mnt/root/finish_install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Variables passed from outer script will be replaced before chroot
HOSTNAME_PLACE="%HOSTNAME%"
USERNAME_PLACE="%USERNAME%"
TIMEZONE_PLACE="%TIMEZONE%"
LOCALE_PLACE="%LOCALE%"
KEYMAP_PLACE="%KEYMAP%"
CRYPT_NAME_PLACE="%CRYPT_NAME%"
LUKS_PART_PLACE="%LUKS_PART%"

# Timezone & locale
ln -sf /usr/share/zoneinfo/${TIMEZONE_PLACE} /etc/localtime
hwclock --systohc
echo "${LOCALE_PLACE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE_PLACE}" > /etc/locale.conf

# Keymap
echo "KEYMAP=${KEYMAP_PLACE}" > /etc/vconsole.conf

# Hostname and hosts
echo "${HOSTNAME_PLACE}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME_PLACE}.localdomain ${HOSTNAME_PLACE}
HOSTS

# Create user and set passwords (we'll set actual passwords from outside using chpasswd)
useradd -m -G wheel -s /bin/bash "${USERNAME_PLACE}"
# Ensure wheel can sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/50-wheel
chmod 0440 /etc/sudoers.d/50-wheel

# mkinitcpio: use systemd + sd-encrypt + btrfs
# Ensure sd-encrypt present and before filesystems
if grep -q '^HOOKS=' /etc/mkinitcpio.conf; then
  sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
else
  echo 'HOOKS=(base systemd autodetect keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)' >> /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Install systemd-boot
bootctl --path=/boot install

# Build loader entry that uses cryptdevice and points root to /dev/mapper/<crypt>
LUKS_UUID=$(blkid -s UUID -o value "${LUKS_PART_PLACE}")
cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 4
editor no
LOADER

cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux (LUKS + BTRFS)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options cryptdevice=UUID=${LUKS_UUID}:${CRYPT_NAME_PLACE} root=/dev/mapper/${CRYPT_NAME_PLACE} rw rootflags=subvol=@
ENTRY

# Enable recommended services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# Create pacman hook so sbctl signs kernels when linux is installed/updated
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/sbctl-sign.hook <<HOOK
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux

[Action]
Description = Signing linux kernel and initramfs with sbctl...
When = PostTransaction
Exec = /usr/bin/sbctl sign -a
HOOK

# sbctl: generate keys and enroll
# Non-destructive (if keys exist, sbctl will not overwrite without prompt)
sbctl create-keys
echo "Attempting to enroll sbctl keys into firmware (may require UEFI prompt/confirmation)..."
sbctl enroll-keys

# Sign kernels and initrds now
sbctl sign -a || true

# Attempt to sign systemd-boot EFI binary so firmware accepts it
BOOT_EFI_PATH="/boot/EFI/systemd/systemd-bootx64.efi"
if [ -f "${BOOT_EFI_PATH}" ]; then
  if [ -f /etc/secure-boot/keys/db.key ]; then
    /usr/bin/sbsign --key /etc/secure-boot/keys/db.key --cert /etc/secure-boot/keys/db.crt --output "${BOOT_EFI_PATH}.signed" "${BOOT_EFI_PATH}" \
      && mv "${BOOT_EFI_PATH}.signed" "${BOOT_EFI_PATH}" \
      || echo "sbsign failed to sign systemd-boot. Check /etc/secure-boot/keys"
  else
    echo "sbctl-generated keys not found at /etc/secure-boot/keys; systemd-boot may need manual signing."
  fi
fi

# Basic sysctl hardening (tune as desired)
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-hardening.conf <<SYSCTL
# Networking
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# IPv6
net.ipv6.conf.all.forwarding = 0
SYSCTL

# Rebuild initramfs to ensure changes applied
mkinitcpio -P

echo "CHROOT CONFIGURATION COMPLETE"
EOF

# Replace placeholders before chroot
sed \
  -e "s|%HOSTNAME%|$HOSTNAME|g" \
  -e "s|%USERNAME%|$USERNAME|g" \
  -e "s|%TIMEZONE%|$TIMEZONE|g" \
  -e "s|%LOCALE%|$LOCALE|g" \
  -e "s|%KEYMAP%|$KEYMAP|g" \
  -e "s|%CRYPT_NAME%|$CRYPT_NAME|g" \
  -e "s|%LUKS_PART%|$LUKS_PART|g" \
  /mnt/root/finish_install.sh > /mnt/root/finish_install.sh.tmp && mv /mnt/root/finish_install.sh.tmp /mnt/root/finish_install.sh
chmod +x /mnt/root/finish_install.sh

# Chroot and run final steps
echo "Entering chroot to finalize installation..."
arch-chroot /mnt /root/finish_install.sh

# Set root and user passwords from outside (less risk of heredoc inside chroot)
echo "Setting root and user passwords..."
arch-chroot /mnt /bin/bash -c "echo root:${ROOT_PW} | chpasswd"
arch-chroot /mnt /bin/bash -c "echo ${USERNAME}:${USER_PW} | chpasswd"

# Final cleanup
echo "Cleaning up and unmounting..."
umount -R /mnt || true
cryptsetup close "$CRYPT_NAME" || true

echo "Installation complete."
echo "IMPORTANT next steps:"
echo " - Reboot into firmware and enable Secure Boot if needed."
echo " - If UEFI prompts for key enrollment, follow the prompts."
echo " - If system won't boot due to unsigned systemd-boot, you may need to manually sign the binary with sbsign and enroll keys."
echo " - Kernel updates will be automatically signed by the pacman hook created (/etc/pacman.d/hooks/sbctl-sign.hook)."
echo
echo "Reboot now? (y/N)"
read -r REBOOT_NOW
if [[ "${REBOOT_NOW,,}" == "y" ]]; then
  reboot
fi
