#!/bin/bash
# Arch Linux LUKS2 + Btrfs install script (dual-boot with Windows on another drive)
# Target: Arch on /dev/sda (SSD) with its own EFI
# Windows is on /dev/nvme0n1 (left untouched)

set -euo pipefail

DISK="/dev/sda"            # your SSD for Arch
EFI_SIZE="512M"
HOSTNAME="archlinux"
USERNAME="archuser"
PASSWORD="password"

# 1. Partition Arch disk
sgdisk --zap-all "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart EFI fat32 1MiB $EFI_SIZE
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary $EFI_SIZE 100%

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"

# 2. Format EFI + LUKS
mkfs.fat -F32 "$EFI_PART"

cryptsetup luksFormat "$ROOT_PART"
cryptsetup open "$ROOT_PART" cryptroot

mkfs.btrfs /dev/mapper/cryptroot -f
mount /dev/mapper/cryptroot /mnt

# 3. Btrfs subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

mount -o subvol=@,compress=zstd,noatime /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,boot/efi}
mount -o subvol=@home,compress=zstd,noatime /dev/mapper/cryptroot /mnt/home

# Mount Arch’s own EFI partition
mount "$EFI_PART" /mnt/boot/efi

# 4. Install base system
pacstrap -K /mnt base linux linux-firmware btrfs-progs vim sudo efibootmgr

# 5. Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 6. Chroot config
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "$HOSTNAME" > /etc/hostname
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Users
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Initramfs
sed -i 's/^HOOKS=(.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Kernel cmdline
ROOT_UUID=\$(blkid -s UUID -o value $ROOT_PART)
echo "rd.luks.name=\$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw" > /etc/kernel/cmdline

# Bootloader: systemd-boot in Arch’s own EFI
bootctl --path=/boot/efi install

cat > /boot/efi/loader/entries/arch.conf <<BOOT
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options \$(cat /etc/kernel/cmdline)
BOOT

cat > /boot/efi/loader/loader.conf <<LOADER
default arch
timeout 3
console-mode max
editor no
LOADER
EOF

umount -R /mnt
cryptsetup close cryptroot
echo "✅ Arch installation complete. Reboot and enjoy dual boot with Windows!"
