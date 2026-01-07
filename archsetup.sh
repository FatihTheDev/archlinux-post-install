#!/bin/bash

set -e
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# ==========================================
# ⚡ TURBO MODE: NETWORK & PACMAN OPTIMIZATION
# ==========================================
echo -e "${BLUE}=== ⚡ Activating Turbo Mode ===${NC}"

# 1. Force Fast DNS (Fixes resolution lag)
echo -e "${GREEN}--> Setting temporary fast DNS (1.1.1.1)...${NC}"
echo "nameserver 1.1.1.1" > /etc/resolv.conf

# 2. Optimize Pacman for RAW SPEED
# - ParallelDownloads=10: Downloads 10 packages at once
# - DisableDownloadTimeout: Kills the "operation too slow" error
# - Color: Makes it pretty
echo -e "${GREEN}--> Optimizing pacman.conf...${NC}"
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
if ! grep -q "DisableDownloadTimeout" /etc/pacman.conf; then
    echo "DisableDownloadTimeout" >> /etc/pacman.conf
fi

# 3. Fix "Hanging" Downloads (Keyring Update)
# Old keys cause pacman to retry verification forever. We fix this first.
echo -e "${GREEN}--> Refreshing keys (prevents validation hangs)...${NC}"
pacman-key --init
pacman -Sy --noconfirm archlinux-keyring

# ==========================================

# Select Disk Function (Simplified)
select_disk() {
    echo -e "\n${YELLOW}Available Disks:${NC}"
    lsblk -dno NAME,SIZE,MODEL | grep -E 'sd|nvme|vd' | awk '{print NR") /dev/"$1" - "$2" "$3}'
    echo ""
    read -p "Enter number of disk to install to: " disk_num
    
    # Map number to disk
    DISK=$(lsblk -dno NAME | grep -E 'sd|nvme|vd' | sed -n "${disk_num}p")
    
    if [[ -z "$DISK" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        exit 1
    fi
    DISK_PATH="/dev/$DISK"
    echo -e "${GREEN}Selected: $DISK_PATH${NC}"
}

# -------------------------------------------
# INTERACTIVE SETUP
# -------------------------------------------

echo -e "\n${BLUE}=== User Configuration ===${NC}"

# Credentials
read -p "Username: " USERNAME
read -s -p "User Password: " USER_PASSWORD
echo ""
read -s -p "Root Password (leave empty to lock): " ROOT_PASSWORD
echo ""

# Disk Selection
select_disk

# GPU Selection (Simple numeric choice for speed)
echo -e "\n${YELLOW}Select GPU Driver:${NC}"
echo "1) Intel"
echo "2) AMD"
echo "3) NVIDIA (Newer)"
echo "4) NVIDIA (Older/Legacy)"
echo "5) VM / None"
read -p "Choice [1-5]: " GPU_NUM

case $GPU_NUM in
    1) GPU_PKG="mesa vulkan-intel intel-media-driver libva-intel-driver" ;;
    2) GPU_PKG="mesa vulkan-radeon libva-mesa-driver" ;;
    3) GPU_PKG="nvidia-open-dkms nvidia-utils nvidia-settings" ;;
    4) GPU_PKG="nvidia nvidia-utils nvidia-settings" ;;
    *) GPU_PKG="mesa" ;;
esac

echo -e "\n${RED}!!! WARNING: THIS WILL WIPE $DISK_PATH !!!${NC}"
read -p "Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then exit 1; fi

# -------------------------------------------
# ⚡ INSTANT MIRROR GENERATION
# -------------------------------------------
echo -e "\n${BLUE}=== Generating Mirrorlist (Instant Mode) ===${NC}"

# We skip speed testing entirely. We ask Arch servers for the "Best Rated" mirrors.
# This takes 2 seconds instead of 2 minutes.
if command -v reflector >/dev/null; then
    # --score sorts by Arch Linux's internal reliability score, not your ping.
    # It assumes high score mirrors are fast enough.
    reflector --score 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
else
    # Fallback: Download pre-generated list
    curl -s "https://archlinux.org/mirrorlist/?country=all&protocol=https&ip_version=4&use_mirror_status=on" | sed -e 's/^#Server/Server/' -e '/^#/d' | head -n 20 > /etc/pacman.d/mirrorlist
fi

# Force DB sync
pacman -Syy

# -------------------------------------------
# AUTOMATED PARTITIONING
# -------------------------------------------
echo -e "\n${BLUE}=== Partitioning & Formatting ===${NC}"

# Wipe
wipefs -a "$DISK_PATH"

# Create Partitions (EFI + Root)
# Use sfdisk for automation (faster/scriptable compared to parted/cfdisk)
if [[ "$DISK_PATH" == *"nvme"* ]]; then
    PART_PREFIX="p"
else
    PART_PREFIX=""
fi

# 1. 512M EFI, 2. Rest Root
echo "label: gpt
,512M,U
,," | sfdisk "$DISK_PATH"

# Define partition paths
EFI_PART="${DISK_PATH}${PART_PREFIX}1"
ROOT_PART="${DISK_PATH}${PART_PREFIX}2"

# Format (Force overwrite)
echo -e "${GREEN}Formatting...${NC}"
mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs -f "$ROOT_PART"

# Mount & Subvolumes
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o subvol=@,compress=zstd:1,noatime "$ROOT_PART" /mnt
mkdir -p /mnt/{home,.snapshots,boot/efi}
mount -o subvol=@home,compress=zstd:1,noatime "$ROOT_PART" /mnt/home
mount -o subvol=@snapshots,compress=zstd:1,noatime "$ROOT_PART" /mnt/.snapshots
mount "$EFI_PART" /mnt/boot/efi

# -------------------------------------------
# BASE INSTALL
# -------------------------------------------
echo -e "\n${BLUE}=== Installing Base System (Parallel) ===${NC}"

# This is where the magic happens. 10 downloads at once.
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs networkmanager grub efibootmgr vim git $GPU_PKG

# -------------------------------------------
# CONFIGURATION
# -------------------------------------------
echo -e "\n${BLUE}=== Configuring System ===${NC}"

# Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Apply the Fast Pacman Config to the NEW system too
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /mnt/etc/pacman.conf

# Chroot Setup
arch-chroot /mnt /bin/bash <<EOF
set -e

# Time & Lang
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "archlinux" > /etc/hostname

# Users
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
if [[ -n "$ROOT_PASSWORD" ]]; then
    echo "root:$ROOT_PASSWORD" | chpasswd
else
    passwd -l root
fi
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Services
systemctl enable NetworkManager

# Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Initramfs (Add btrfs)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems btrfs fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
EOF

echo -e "\n${GREEN}=== ⚡ INSTALLATION COMPLETE! ===${NC}"
echo "You can now reboot."
echo "1. umount -R /mnt"
echo "2. reboot"
