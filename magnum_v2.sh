#!/usr/bin/env bash
# arch-install-luks-btrfs-uki.sh
# Opinionated installer script for Arch Linux (UEFI) on /dev/sda
# Features:
# - GPT with an EFI partition and a single LUKS2-encrypted partition
# - Btrfs on the LUKS container with recommended subvolumes
# - Unified Kernel Image (UKI) via dracut hooks
# - Optional Secure Boot via sbctl
#
# WARNING: This script is destructive. It WILL wipe the target disk.
# Edit variables below before running. Run from an Arch live USB as root.
# Tested conceptually; review before use.

set -euo pipefail
IFS=$'\n\t'

### === USER CONFIGURATION (EDIT BEFORE RUNNING) ===
DISK="/dev/sda"                 # target disk
EFI_SIZE="1G"                    # EFI partition size
EFI_PART="${DISK}1"
CRYPT_PART="${DISK}2"
CRYPT_NAME="cryptroot"
BTRFS_SUBVOL_ROOT="@"
BTRFS_SUBVOL_HOME="@home"
BTRFS_SUBVOL_LOG="@log"
BTRFS_SUBVOL_CACHE="@cache"
USERNAME="youruser"
ROOT_PASS=""                      # leave empty to be prompted
USER_PASS=""                      # leave empty to be prompted
LOCALE="en_US.UTF-8"
TIMEZONE="UTC"
KEYMAP="us"
UCODE_PKG="amd-ucode"             # set to intel-ucode for Intel CPUs
USE_SECUREBOOT="yes"              # yes/no

# Packages to install in base system
BASE_PKGS=(base linux linux-firmware ${UCODE_PKG} sudo vim dracut sbsigntools iwd git efibootmgr binutils networkmanager btrfs-progs)
if [ "$USE_SECUREBOOT" = "yes" ]; then
  BASE_PKGS+=(sbctl)
fi

### === END USER CONFIG ===

# Helper: prompt for password if not provided
read_passwords() {
  if [ -z "$ROOT_PASS" ]; then
    echo "Set root password:"
    passwd root || true
    # If passwd didn't set programmatically, ask user for value to store for later use
    read -s -p "Enter root password again for script (will not be echoed): " rp; echo
    ROOT_PASS="$rp"
  fi

  if [ -z "$USER_PASS" ]; then
    read -s -p "Enter password for user '$USERNAME': " up; echo
    USER_PASS="$up"
  fi
}

confirm() {
  echo
  echo "*** WARNING: This will DESTROY all data on $DISK ***"
  echo "Target disk: $DISK"
  echo "EFI partition: $EFI_PART"
  echo "Encrypted partition: $CRYPT_PART -> mapper: /dev/mapper/$CRYPT_NAME"
  echo "BTRFS subvolumes: $BTRFS_SUBVOL_ROOT, $BTRFS_SUBVOL_HOME, $BTRFS_SUBVOL_LOG, $BTRFS_SUBVOL_CACHE"
  echo
  read -p "Type 'YES' to continue: " ans
  if [ "$ans" != "YES" ]; then
    echo "Aborting."
    exit 1
  fi
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root from an Arch live USB." >&2
    exit 1
  fi
}

partition_disk() {
  echo "Partitioning $DISK..."
  # Wipe existing partition table
  sgdisk --zap-all "$DISK"

  # Create EFI partition
  sgdisk -n 1:0:+${EFI_SIZE} -t 1:EF00 -c 1:"EFI" "$DISK"
  # Create LUKS partition with remaining space
  sgdisk -n 2:0:0 -t 2:8309 -c 2:"cryptluks" "$DISK"

  partprobe "$DISK"
  sleep 1
}

format_efi() {
  echo "Formatting EFI: $EFI_PART"
  mkfs.fat -F32 "$EFI_PART"
}

setup_luks() {
  echo "Setting up LUKS2 on $CRYPT_PART"
  cryptsetup luksFormat --type luks2 "$CRYPT_PART"
  cryptsetup open --allow-discards --persistent "$CRYPT_PART" "$CRYPT_NAME"
}

format_btrfs_and_subvols() {
  echo "Formatting Btrfs on /dev/mapper/$CRYPT_NAME"
  mkfs.btrfs -f /dev/mapper/$CRYPT_NAME

  mount /dev/mapper/$CRYPT_NAME /mnt
  btrfs subvolume create /mnt/$BTRFS_SUBVOL_ROOT
  btrfs subvolume create /mnt/$BTRFS_SUBVOL_HOME
  btrfs subvolume create /mnt/$BTRFS_SUBVOL_LOG
  btrfs subvolume create /mnt/$BTRFS_SUBVOL_CACHE
  umount /mnt

  mkdir -p /mnt
  mount -o compress=zstd,subvol=$BTRFS_SUBVOL_ROOT /dev/mapper/$CRYPT_NAME /mnt
  mkdir -p /mnt/{home,var/log,var/cache,boot/efi}
  mount -o compress=zstd,subvol=$BTRFS_SUBVOL_HOME /dev/mapper/$CRYPT_NAME /mnt/home
  mount -o compress=zstd,subvol=$BTRFS_SUBVOL_LOG /dev/mapper/$CRYPT_NAME /mnt/var/log
  mount -o compress=zstd,subvol=$BTRFS_SUBVOL_CACHE /dev/mapper/$CRYPT_NAME /mnt/var/cache

  mount "$EFI_PART" /mnt/boot/efi
}

bootstrap_system() {
  echo "Bootstrapping Arch base system..."
  pacman -Sy --noconfirm pacman
  pacstrap /mnt "${BASE_PKGS[@]}"
  genfstab -U /mnt >> /mnt/etc/fstab
}

chroot_config() {
  echo "Entering chroot to configure the new system..."

  # Prepare a script to run inside chroot
  cat > /mnt/root/inner-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail

# This script runs inside chroot
export LANG="${LOCALE}"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime || true
hwclock --systohc || true

# locale
sed -i "s/^#\(${LOCALE}\)/\1/" /etc/locale.gen || true
locale-gen || true
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

echo "${HOSTNAME:-arch}" > /etc/hostname

# create user
useradd -m -G wheel ${USERNAME}
# set passwords
chpasswd <<EOF
root:${ROOT_PASS}
${USERNAME}:${USER_PASS}
EOF

# sudoers
sed -i 's/^# %wheel/%wheel/' /etc/sudoers || true

# enable services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# dracut hooks + scripts for UKI generation
mkdir -p /usr/local/bin
cat > /usr/local/bin/dracut-install.sh <<'DRI'
#!/usr/bin/env bash
set -e
mkdir -p /boot/efi/EFI/Linux
while read -r line; do
  if [[ "$line" == usr/lib/modules/*/pkgbase ]]; then
    kver="${line#usr/lib/modules/}"
    kver="${kver%/pkgbase}"
    dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64.efi
  fi
done
DRI
chmod +x /usr/local/bin/dracut-install.sh

cat > /usr/local/bin/dracut-remove.sh <<'DRR'
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/bootx64.efi
DRR
chmod +x /usr/local/bin/dracut-remove.sh

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/90-dracut-install.hook <<'HOOK1'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Updating linux EFI image
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
Depends = dracut
NeedsTargets
HOOK1

cat > /etc/pacman.d/hooks/60-dracut-remove.hook <<'HOOK2'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Removing linux EFI image
When = PreTransaction
Exec = /usr/local/bin/dracut-remove.sh
NeedsTargets
HOOK2

# dracut config files
mkdir -p /etc/dracut.conf.d
# UUID will be injected by outer script after blkid
cat > /etc/dracut.conf.d/flags.conf <<'DFL'
compress="zstd"
hostonly="no"
DFL

# install linux (this will trigger dracut hook and produce UKI)
pacman -S --noconfirm linux || true

CHROOT

  # copy variables into chroot script via envsubst
  export LOCALE TIMEZONE KEYMAP USERNAME ROOT_PASS USER_PASS
  export HOSTNAME=$(cat /mnt/etc/hostname 2>/dev/null || echo arch)
  # inject values
  sed -i "s|\${LOCALE}|${LOCALE}|g; s|\${TIMEZONE}|${TIMEZONE}|g; s|\${KEYMAP}|${KEYMAP}|g; s|\${USERNAME}|${USERNAME}|g; s|\${ROOT_PASS}|${ROOT_PASS}|g; s|\${USER_PASS}|${USER_PASS}|g; s|\${HOSTNAME}|${HOSTNAME:-arch}|g" /mnt/root/inner-setup.sh

  chmod +x /mnt/root/inner-setup.sh
  arch-chroot /mnt /root/inner-setup.sh

  # After chroot script, create dracut cmdline conf with correct UUID
  blkid -s UUID -o value ${CRYPT_PART} > /mnt/etc/dracut.conf.d/luks-uuid.tmp || true
  UUID=$(cat /mnt/etc/dracut.conf.d/luks-uuid.tmp || true)
  cat > /mnt/etc/dracut.conf.d/cmdline.conf <<CMD
kernel_cmdline="rd.luks.uuid=luks-${UUID} root=/dev/mapper/${CRYPT_NAME} rootfstype=btrfs rootflags=subvol=${BTRFS_SUBVOL_ROOT},rw,relatime,compress=zstd"
CMD

  # If secure boot requested, configure sbctl inside chroot
  if [ "${USE_SECUREBOOT}" = "yes" ]; then
    arch-chroot /mnt /bin/bash -c "sbctl create-keys || true; sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi || true"
    cat > /mnt/etc/dracut.conf.d/secureboot.conf <<SBC
uefi_secureboot_cert=\"/var/lib/sbctl/keys/db/db.pem\"
uefi_secureboot_key=\"/var/lib/sbctl/keys/db/db.key\"
SBC
    # create sbctl pacman hook (overrides default)
    cat > /mnt/etc/pacman.d/hooks/zz-sbctl.hook <<'SBHOOK'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = boot/*
Target = efi/*
Target = usr/lib/modules/*/vmlinuz
Target = usr/lib/initcpio/*
Target = usr/lib/**/efi/*.efi*

[Action]
Description = Signing EFI binaries...
When = PostTransaction
Exec = /usr/bin/sbctl sign /boot/efi/EFI/Linux/bootx64.efi
SBHOOK
    # attempt to enroll keys (may prompt)
    arch-chroot /mnt /bin/bash -c "sbctl enroll-keys --microsoft || true"
  fi

  # create efiboot entry
  efibootmgr --create --disk ${DISK} --part 1 --label "Arch Linux" --loader 'EFI\\Linux\\bootx64.efi' --unicode || true

  echo "Inner configuration finished."
}

### === main flow ===
check_root
confirm
read_passwords
partition_disk
format_efi
setup_luks
format_btrfs_and_subvols
bootstrap_system
chroot_config

echo
echo "Installation finished — please reboot."
echo "Notes:"
echo " - SecureBoot was set to: $USE_SECUREBOOT"
if [ "$USE_SECUREBOOT" = "yes" ]; then
  echo " - If you enrolled keys, enable Secure Boot in BIOS and set Setup Mode accordingly."
fi
echo " - The system should have an EFI entry named 'Arch Linux' pointing to EFI\\Linux\\bootx64.efi"

echo "Reboot now? (y/N)"
read -r REBOOT_ANS || true
if [ "$REBOOT_ANS" = "y" ] || [ "$REBOOT_ANS" = "Y" ]; then
  umount -R /mnt || true
  cryptsetup close "$CRYPT_NAME" || true
  reboot
fi
