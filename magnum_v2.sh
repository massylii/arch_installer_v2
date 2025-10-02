#!/bin/bash
# Arch Linux LUKS2 + Btrfs install script (dual-boot with Windows on another drive)
# Target: Arch on /dev/sda (SSD) with its own EFI
# Windows is on /dev/nvme0n1 (left untouched)

set -euo pipefail

DISK="/dev/sda"
EFI_SIZE="512M"
HOSTNAME="archlinux"
USERNAME="archuser"
PASSWORD="password"
LUKS_PASSWORD="lukspassword"  # Set your LUKS passphrase

# 1. Partition Arch disk
echo "Partitioning $DISK..."
sgdisk --zap-all "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart EFI fat32 1MiB "$EFI_SIZE"
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary "$EFI_SIZE" 100%

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"

# 2. Format EFI + LUKS (non-interactive)
echo "Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"
echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat "$ROOT_PART" -
echo -n "$LUKS_PASSWORD" | cryptsetup open "$ROOT_PART" cryptroot -
mkfs.btrfs /dev/mapper/cryptroot -f
mount /dev/mapper/cryptroot /mnt

# 3. Btrfs subvolumes
echo "Creating Btrfs subvolumes..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@snapshots
umount /mnt

# Mount with full layout
echo "Mounting subvolumes..."
mount -o subvol=@,compress=zstd,noatime /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var,opt,tmp,.snapshots,boot}
mount -o subvol=@home,compress=zstd,noatime /dev/mapper/cryptroot /mnt/home
mount -o subvol=@var,compress=zstd,noatime /dev/mapper/cryptroot /mnt/var
mount -o subvol=@opt,compress=zstd,noatime /dev/mapper/cryptroot /mnt/opt
mount -o subvol=@tmp,compress=zstd,noatime /dev/mapper/cryptroot /mnt/tmp
mount -o subvol=@snapshots,compress=zstd,noatime /dev/mapper/cryptroot /mnt/.snapshots

# Mount Arch's EFI partition directly at /boot
mount "$EFI_PART" /mnt/boot

# 4. Install base system
echo "Installing base system..."
pacstrap -K /mnt base linux linux-firmware btrfs-progs vim sudo efibootmgr sbctl

# 5. Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Get ROOT_PART UUID before chroot
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# 6. Chroot config
echo "Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# Timezone & locale
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
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Initramfs with systemd-based encryption
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader: systemd-boot
bootctl --path=/boot install

# Create boot entry
cat > /boot/loader/entries/arch.conf <<BOOT
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rd.luks.name=$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash
BOOT

cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 3
console-mode max
editor no
LOADER

# Secure Boot setup
echo "Setting up Secure Boot..."
sbctl create-keys
sbctl enroll-keys --microsoft

# Sign bootloader and kernel
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
sbctl sign -s /boot/vmlinuz-linux

# Verify signatures
sbctl verify

EOF

# Cleanup
echo "Cleaning up..."
umount -R /mnt
cryptsetup close cryptroot

echo ""
echo "✅ Arch installation complete!"
echo ""
echo "Next steps:"
echo "1. Reboot and enable Secure Boot in UEFI"
echo "2. Select 'Arch Linux' from boot menu"
echo "3. Enter LUKS password: $LUKS_PASSWORD"
echo ""
echo "Windows should still boot from /dev/nvme0n1's EFI partition"
