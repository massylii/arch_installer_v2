#!/usr/bin/env bash

# Automated Secure Arch Linux Installation Script
# Based on Ataraxxia's secure-arch guide with modifications:
# - Removed LVM
# - Added btrfs filesystem
# - Enhanced LUKS2 encryption settings
# - Automated installation process

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables - MODIFY THESE
DISK="/dev/nvme0n1"  # Change this to your target disk
EFI_SIZE="1024M"
USERNAME="user"      # Change to your desired username
HOSTNAME="archlinux" # Change to your desired hostname
TIMEZONE="Europe/London"  # Change to your timezone
LOCALE="en_GB.UTF-8"      # Change to your locale
KEYMAP="us"               # Change to your keymap
CPU_VENDOR="intel"        # Change to "amd" if you have AMD CPU

# Partition variables
EFI_PART="${DISK}p1"
ROOT_PART="${DISK}p2"

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

prompt_continue() {
    echo -e "${BLUE}[PROMPT]${NC} $1"
    read -p "Continue? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation aborted."
        exit 1
    fi
}

check_uefi() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        error "This system is not booted in UEFI mode!"
    fi
    log "UEFI mode confirmed"
}

check_internet() {
    if ! ping -c 1 archlinux.org &> /dev/null; then
        error "No internet connection! Please configure your network first."
    fi
    log "Internet connection confirmed"
}

setup_pacman_keys() {
    log "Setting up pacman keys..."
    pacman-key --init
    pacman-key --populate archlinux
}

partition_disk() {
    log "Partitioning disk: $DISK"
    
    # Create GPT partition table and partitions
    sgdisk --zap-all "$DISK"
    sgdisk --clear \
           --new=1:0:+${EFI_SIZE} --typecode=1:ef00 --change-name=1:'EFI System Partition' \
           --new=2:0:0 --typecode=2:8309 --change-name=2:'Linux LUKS' \
           "$DISK"
    
    # Inform kernel of partition changes
    partprobe "$DISK"
    sleep 2
    
    log "Partition table created"
    sgdisk --print "$DISK"
}

format_efi() {
    log "Formatting EFI partition..."
    mkfs.fat -F32 -n "EFI" "$EFI_PART"
}

setup_encryption() {
    log "Setting up LUKS2 encryption with enhanced security..."
    echo "Enter passphrase for disk encryption:"
    
    cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --hash sha512 \
        --iter-time 5000 \
        --key-size 512 \
        --pbkdf argon2id \
        --use-urandom \
        --verify-passphrase \
        "$ROOT_PART"
    
    log "Opening encrypted volume..."
    echo "Enter passphrase to open the encrypted volume:"
    cryptsetup open --allow-discards --persistent "$ROOT_PART" cryptroot
}

format_btrfs() {
    log "Creating btrfs filesystem..."
    mkfs.btrfs -f -L "ArchRoot" /dev/mapper/cryptroot
    
    # Mount and create subvolumes
    mount /dev/mapper/cryptroot /mnt
    
    log "Creating btrfs subvolumes..."
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@tmp
    btrfs subvolume create /mnt/@snapshots
    
    # Unmount to remount with proper subvolumes
    umount /mnt
    
    # Mount subvolumes with proper options
    mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt
    
    mkdir -p /mnt/{home,var,tmp,.snapshots,boot}
    mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@home /dev/mapper/cryptroot /mnt/home
    mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@var /dev/mapper/cryptroot /mnt/var
    mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@tmp /dev/mapper/cryptroot /mnt/tmp
    mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
    
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
    
    log "Btrfs filesystem and subvolumes created"
}

install_base_system() {
    log "Installing base system..."
    
    # Determine microcode package
    local ucode_pkg=""
    if [[ "$CPU_VENDOR" == "intel" ]]; then
        ucode_pkg="intel-ucode"
    elif [[ "$CPU_VENDOR" == "amd" ]]; then
        ucode_pkg="amd-ucode"
    else
        error "Invalid CPU vendor. Use 'intel' or 'amd'"
    fi
    
    pacstrap /mnt \
        base \
        linux \
        linux-firmware \
        "$ucode_pkg" \
        sudo \
        vim \
        dracut \
        sbsigntools \
        iwd \
        git \
        efibootmgr \
        binutils \
        networkmanager \
        btrfs-progs \
        man-db
    
    log "Base system installed"
}

generate_fstab() {
    log "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    
    # Show generated fstab
    echo "Generated fstab:"
    cat /mnt/etc/fstab
}

configure_system() {
    log "Configuring system in chroot..."
    
    # Create configuration script to run in chroot
    cat > /mnt/configure.sh << EOF
#!/bin/bash
set -euo pipefail

# Set root password
echo "Setting root password..."
echo "root:$ROOT_PASSWORD" | chpasswd

# Set timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Set locale
sed -i 's/#$LOCALE/$LOCALE/' /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Set keymap
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "FONT=Lat2-Terminus16" >> /etc/vconsole.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname

# Create user
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Configure sudo
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Enable services
systemctl enable NetworkManager
systemctl enable fstrim.timer

echo "System configuration completed"
EOF
    
    # Make script executable
    chmod +x /mnt/configure.sh
    
    # Prompt for passwords
    echo "Enter root password:"
    read -s ROOT_PASSWORD
    echo "Enter user password for $USERNAME:"
    read -s USER_PASSWORD
    
    # Export passwords for the chroot script
    export ROOT_PASSWORD USER_PASSWORD
    
    # Run configuration in chroot
    arch-chroot /mnt /configure.sh
    
    # Clean up
    rm /mnt/configure.sh
}

setup_dracut() {
    log "Setting up dracut for unified kernel image..."
    
    # Create dracut install script
    cat > /mnt/usr/local/bin/dracut-install.sh << 'EOF'
#!/usr/bin/env bash

mkdir -p /boot/efi/EFI/Linux

while read -r line; do
    if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
        kver="${line#'usr/lib/modules/'}"
        kver="${kver%'/pkgbase'}"

        dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64.efi
    fi
done
EOF

    # Create dracut remove script
    cat > /mnt/usr/local/bin/dracut-remove.sh << 'EOF'
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/bootx64.efi
EOF

    # Make scripts executable
    chmod +x /mnt/usr/local/bin/dracut-*
    
    # Create hooks directory
    mkdir -p /mnt/etc/pacman.d/hooks
    
    # Create install hook
    cat > /mnt/etc/pacman.d/hooks/90-dracut-install.hook << 'EOF'
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
EOF

    # Create remove hook
    cat > /mnt/etc/pacman.d/hooks/60-dracut-remove.hook << 'EOF'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Removing linux EFI image
When = PreTransaction
Exec = /usr/local/bin/dracut-remove.sh
NeedsTargets
EOF

    # Get LUKS UUID
    local LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    
    # Create dracut kernel command line
    cat > /mnt/etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.uuid=luks-$LUKS_UUID root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=rw,noatime,compress=zstd:3,space_cache=v2,subvol=@"
EOF

    # Create dracut flags
    cat > /mnt/etc/dracut.conf.d/flags.conf << 'EOF'
compress="zstd"
hostonly="no"
EOF

    log "Dracut configuration completed"
}

generate_uki() {
    log "Generating unified kernel image..."
    arch-chroot /mnt pacman -S --noconfirm linux
    
    if [[ ! -f /mnt/boot/efi/EFI/Linux/bootx64.efi ]]; then
        error "Unified kernel image was not created!"
    fi
    
    log "Unified kernel image created successfully"
}

setup_boot_entry() {
    log "Creating UEFI boot entry..."
    
    # Create boot entry
    arch-chroot /mnt efibootmgr --create --disk "$DISK" --part 1 --label "Arch Linux" --loader 'EFI\Linux\bootx64.efi' --unicode
    
    # Show boot entries
    arch-chroot /mnt efibootmgr
    
    warn "Please note the Arch Linux boot entry number and set it as the first boot option in your BIOS if needed"
}

setup_secureboot() {
    log "Setting up Secure Boot..."
    
    # Install sbctl
    arch-chroot /mnt pacman -S --noconfirm sbctl
    
    # Create keys and sign binaries
    arch-chroot /mnt sbctl create-keys
    arch-chroot /mnt sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
    
    # Configure dracut for secure boot
    cat > /mnt/etc/dracut.conf.d/secureboot.conf << 'EOF'
uefi_secureboot_cert="/var/lib/sbctl/keys/db/db.pem"
uefi_secureboot_key="/var/lib/sbctl/keys/db/db.key"
EOF

    # Create sbctl hook
    cat > /mnt/etc/pacman.d/hooks/zz-sbctl.hook << 'EOF'
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
EOF

    warn "IMPORTANT: Before rebooting, you need to:"
    warn "1. Reboot and enter BIOS/UEFI settings"
    warn "2. Enable Setup Mode for Secure Boot"
    warn "3. Clear/erase existing Secure Boot keys"
    warn "4. Boot back into Arch Linux"
    warn "5. Run: sudo sbctl enroll-keys --microsoft"
    warn "6. Reboot and enable Secure Boot in BIOS"
}

cleanup() {
    log "Cleaning up..."
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
}

prompt_continue() {
    echo -e "${BLUE}[PROMPT]${NC} $1"
    read -p "Continue? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation aborted."
        exit 1
    fi
}

main() {
    log "Starting automated Arch Linux installation..."
    
    # Pre-flight checks
    check_uefi
    check_internet
    
    # Interactive configuration
    prompt_disk_selection
    prompt_basic_config
    
    # Show final configuration
    echo -e "${BLUE}Final Installation Configuration:${NC}"
    echo "Disk: $DISK"
    echo "EFI Partition: $EFI_PART"
    echo "Root Partition: $ROOT_PART"
    echo "Username: $USERNAME"
    echo "Hostname: $HOSTNAME"
    echo "Timezone: $TIMEZONE"
    echo "Locale: $LOCALE"
    echo "Keymap: $KEYMAP"
    echo "CPU: $CPU_VENDOR"
    echo
    
    prompt_continue "Proceed with installation?"
    
    # Setup pacman
    setup_pacman_keys
    
    # Disk operations
    partition_disk
    format_efi
    setup_encryption
    format_btrfs
    
    # System installation
    install_base_system
    generate_fstab
    configure_system
    
    # Boot setup
    setup_dracut
    generate_uki
    setup_boot_entry
    
    # Security setup
    setup_secureboot
    
    log "Installation completed successfully!"
    warn "Remember to complete the Secure Boot setup as mentioned above."
    warn "You can reboot now and your system should boot with the encrypted root partition."
    
    prompt_continue "Reboot now?"
    reboot
}

# Trap to cleanup on exit
trap cleanup EXIT

# Run main function
main "$@"
