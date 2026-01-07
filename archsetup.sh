#!/bin/bash

set -e
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}" 
    exit 1
fi

# Check if we're in Arch Linux live environment
if ! command -v pacman >/dev/null 2>&1; then
    echo -e "${RED}Error: This script must be run from Arch Linux live environment${NC}" >&2
    exit 1
fi

# ==========================================
# 🚀 SPEED & STABILITY OPTIMIZATIONS
# ==========================================
echo -e "${GREEN}Optimizing download settings for the Live Environment...${NC}"

# 1. Enable Parallel Downloads IMMEDIATELY in the live environment
# This makes 'pacstrap' and initial package installs 5x-10x faster
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf

# 2. Disable strict timeout checks on the live ISO to prevent "too slow" errors on single files
# We modify the XferCommand to be more resilient if possible, or rely on parallel downloads
# (Standard pacman.conf usually handles this well if ParallelDownloads is on)

# 3. Update Keyring FIRST
# Stale keys are the #1 cause of "hanging" downloads that look like timeouts
echo -e "${GREEN}Refreshing Arch Linux Keyring (prevents validation hangs)...${NC}"
pacman -Sy --noconfirm archlinux-keyring

# ==========================================

# Check if /mnt is already mounted
if mountpoint -q /mnt; then
    echo -e "${YELLOW}Warning: /mnt is already mounted. Unmounting...${NC}"
    umount -R /mnt 2>/dev/null || true
fi

# Install fzf for better selection interface
echo -e "${GREEN}Installing fzf for interactive selection...${NC}"
if ! command -v fzf >/dev/null 2>&1; then
    pacman -S --noconfirm fzf 2>/dev/null || echo -e "${YELLOW}Warning: Could not install fzf, will use fallback${NC}"
fi

# Function to select from list using fzf or fallback to dialog
select_option() {
    local prompt="$1"
    shift
    local options=("$@")
    local result
    
    if command -v fzf >/dev/null 2>&1; then
        result=$(printf '%s\n' "${options[@]}" | fzf --prompt="$prompt: " --height=40% --reverse)
        echo "$result"
    elif command -v dialog >/dev/null 2>&1; then
        local menu_items=()
        local i=0
        for opt in "${options[@]}"; do
            menu_items+=("$i" "$opt")
            ((i++))
        done
        result=$(dialog --stdout --menu "$prompt" 0 0 0 "${menu_items[@]}")
        if [[ -n "$result" ]]; then
            echo "${options[$result]}"
        fi
    else
        # Fallback to numbered list
        echo "$prompt" >&2
        local i=1
        for opt in "${options[@]}"; do
            echo "  $i) $opt" >&2
            ((i++))
        done
        echo -n "Enter choice [1-$((i-1))]: " >&2
        local choice
        if [[ -t 0 ]]; then
            read choice
        else
            read choice < /dev/tty
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -lt $i ]]; then
            echo "${options[$((choice-1))]}"
        fi
    fi
}

# Function to get user input
get_input() {
    local prompt="$1"
    local default="${2:-}"
    local secret="${3:-false}"
    local result
    
    if command -v dialog >/dev/null 2>&1; then
        if [[ "$secret" == "true" ]]; then
            result=$(dialog --stdout --insecure --passwordbox "$prompt" 0 0 "$default")
        else
            result=$(dialog --stdout --inputbox "$prompt" 0 0 "$default")
        fi
        echo "$result"
    else
        if [[ "$secret" == "true" ]]; then
            if [[ -t 0 ]]; then
                read -sp "$prompt: " input
            else
                read -sp "$prompt: " input < /dev/tty
            fi
            echo >&2
            echo "$input"
        else
            if [[ -t 0 ]]; then
                read -p "$prompt: " input
            else
                read -p "$prompt: " input < /dev/tty
            fi
            echo "${input:-$default}"
        fi
    fi
}

# Function to get yes/no answer
get_yesno() {
    local prompt="$1"
    
    if command -v dialog >/dev/null 2>&1; then
        dialog --yesno "$prompt" 0 0 2>&1 >/dev/tty
        return $?
    else
        if [[ -t 0 ]]; then
            read -p "$prompt (y/n): " answer
        else
            read -p "$prompt (y/n): " answer < /dev/tty
        fi
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

# Collect user information
echo -e "${GREEN}=== Arch Linux Installation Script ===${NC}\n"

# Root password
echo -n "Enter root password (leave empty to lock root account): "
if [[ -t 0 ]]; then
    read -s ROOT_PASSWORD
else
    read -s ROOT_PASSWORD < /dev/tty
fi
echo ""
if [[ -z "$ROOT_PASSWORD" ]]; then
    LOCK_ROOT=true
    echo -e "${YELLOW}Root account will be locked${NC}"
else
    LOCK_ROOT=false
fi

# Username
echo -n "Enter username: "
if [[ -t 0 ]]; then
    read USERNAME
else
    read USERNAME < /dev/tty
fi
if [[ -z "$USERNAME" ]]; then
    echo -e "${RED}Error: Username cannot be empty${NC}" >&2
    exit 1
fi

# User password
echo -n "Enter user password: "
if [[ -t 0 ]]; then
    read -s USER_PASSWORD
else
    read -s USER_PASSWORD < /dev/tty
fi
echo ""
if [[ -z "$USER_PASSWORD" ]]; then
    echo -e "${RED}Error: User password cannot be empty${NC}" >&2
    exit 1
fi

# Confirm password
echo -n "Confirm user password: "
if [[ -t 0 ]]; then
    read -s CONFIRM_PASSWORD
else
    read -s CONFIRM_PASSWORD < /dev/tty
fi
echo ""
if [[ "$USER_PASSWORD" != "$CONFIRM_PASSWORD" ]]; then
    echo -e "${RED}Error: Passwords do not match${NC}" >&2
    exit 1
fi

# Disk selection
echo -e "\n${GREEN}Detecting disks...${NC}"
DISKS=($(lsblk -dno NAME | grep -E '^[sv]d[a-z]$|^nvme[0-9]+n[0-9]+$'))
if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No disks found${NC}" >&2
    exit 1
fi

DISK_OPTIONS=()
for disk in "${DISKS[@]}"; do
    SIZE=$(lsblk -bdno SIZE "/dev/$disk")
    DISK_OPTIONS+=("$disk ($SIZE)")
done

SELECTED_DISK_OPTION=$(select_option "Select disk to install Arch Linux" "${DISK_OPTIONS[@]}")
if [[ -z "$SELECTED_DISK_OPTION" ]]; then
    echo -e "${RED}Error: Disk selection cancelled${NC}" >&2
    exit 1
fi
SELECTED_DISK=$(echo "$SELECTED_DISK_OPTION" | awk '{print $1}')
DISK_PATH="/dev/$SELECTED_DISK"

# Partitioning method
PARTITION_METHOD=$(select_option "Select partitioning method" \
    "Use entire disk" \
    "Use remaining free space" \
    "Manual partitioning (cfdisk)")
if [[ -z "$PARTITION_METHOD" ]]; then
    echo -e "${RED}Error: Partitioning method selection cancelled${NC}" >&2
    exit 1
fi

# GPU selection
GPU_CHOICE=$(select_option "Select your GPU" \
    "Intel" \
    "AMD" \
    "NVIDIA (newer)" \
    "NVIDIA (older)")
if [[ -z "$GPU_CHOICE" ]]; then
    echo -e "${RED}Error: GPU selection cancelled${NC}" >&2
    exit 1
fi

# Mirror countries
COUNTRY_OPTIONS=(
    "US United States"
    "DE Germany"
    "GB United Kingdom"
    "FR France"
    "NL Netherlands"
    "SE Sweden"
    "CA Canada"
    "AU Australia"
    "JP Japan"
    "KR South Korea"
    "SG Singapore"
    "IN India"
    "BR Brazil"
    "PL Poland"
    "CZ Czech Republic"
    "IT Italy"
    "ES Spain"
    "CH Switzerland"
    "AT Austria"
    "DK Denmark"
    "NO Norway"
    "FI Finland"
    "CN China"
)

MIRROR_COUNTRIES=""
if command -v fzf >/dev/null 2>&1; then
    MIRROR_COUNTRIES=$(printf '%s\n' "${COUNTRY_OPTIONS[@]}" | fzf -m --prompt="Select mirror countries (TAB to multi-select, Esc for global): " --height=50% --reverse --border | awk '{print $1}' | paste -sd',' -)
else
    echo -n "Enter comma-separated country codes (e.g. US,DE) or leave empty for global: "
    if [[ -t 0 ]]; then
        read MIRROR_COUNTRIES
    else
        read MIRROR_COUNTRIES < /dev/tty
    fi
    MIRROR_COUNTRIES=${MIRROR_COUNTRIES^^}
fi

# Printing support
if get_yesno "Do you want printing support (CUPS)?"; then
    INSTALL_CUPS=true
else
    INSTALL_CUPS=false
fi

# Confirmation
echo -e "\n${YELLOW}=== Installation Summary ===${NC}"
echo "Username: $USERNAME"
echo "Root account: $([ "$LOCK_ROOT" = true ] && echo "Locked" || echo "Enabled")"
echo "Disk: $DISK_PATH"
echo "Partitioning: $PARTITION_METHOD"
echo "GPU: $GPU_CHOICE"
echo "Mirror Countries: ${MIRROR_COUNTRIES:-Global Fastest}"
echo "Printing support: $([ "$INSTALL_CUPS" = true ] && echo "Yes" || echo "No")"
echo ""

if ! get_yesno "Proceed with installation?"; then
    echo "Installation cancelled."
    exit 0
fi

# Function to partition disk
partition_disk() {
    local disk="$1"
    local method="$2"
    
    case "$method" in
        "Use entire disk")
            echo -e "${GREEN}Partitioning entire disk...${NC}"
            parted -s "$disk" mklabel gpt
            parted -s "$disk" mkpart primary fat32 1MiB 513MiB
            parted -s "$disk" set 1 esp on
            EFI_PART="${disk}1"
            # Using entire rest of disk
            parted -s "$disk" mkpart primary btrfs 513MiB 100%
            ROOT_PART="${disk}2"
            ;;
            
        "Use remaining free space")
            echo -e "${GREEN}Detecting free space...${NC}"
            if ! parted -s "$disk" print &>/dev/null; then
                echo -e "${RED}Error: Disk has no partition table.${NC}" >&2
                exit 1
            fi
            
            DISK_SIZE=$(parted -s "$disk" unit MiB print | grep "^Disk" | awk '{print $3}' | sed 's/MiB//')
            LAST_PART=$(parted -s "$disk" unit MiB print | grep -E '^[[:space:]]*[0-9]+' | tail -1)
            
            if [[ -n "$LAST_PART" ]]; then
                LAST_END=$(echo "$LAST_PART" | awk '{print $3}' | sed 's/MiB//')
            else
                LAST_END=1
            fi
            
            START_POS=$((LAST_END + 1))
            AVAILABLE_SPACE=$((DISK_SIZE - START_POS))
            
            if [[ $AVAILABLE_SPACE -lt 2048 ]]; then
                echo -e "${RED}Error: Not enough free space (need 2GB+).${NC}" >&2
                exit 1
            fi
            
            # Check for existing EFI
            if ! parted -s "$disk" print | grep -q "esp on"; then
                EFI_START=$START_POS
                EFI_END=$((START_POS + 512))
                parted -s "$disk" mkpart primary fat32 "${EFI_START}MiB" "${EFI_END}MiB"
                PART_NUM=$(parted -s "$disk" print | tail -1 | awk '{print $1}')
                parted -s "$disk" set "$PART_NUM" esp on
                START_POS=$EFI_END
            fi
            
            parted -s "$disk" mkpart primary btrfs "${START_POS}MiB" 100%
            ROOT_PART="${disk}$(parted -s "$disk" print | tail -1 | awk '{print $1}')"
            
            EFI_PART_NUM=$(parted -s "$disk" print | grep "esp on" | awk '{print $1}')
            if [[ -n "$EFI_PART_NUM" ]]; then
                EFI_PART="${disk}${EFI_PART_NUM}"
            fi
            ;;
            
        "Manual partitioning (cfdisk)")
            echo -e "${GREEN}Opening cfdisk...${NC}"
            echo "REQUIRED: 1. EFI (Type: EFI System), 2. Root (Type: Linux filesystem)"
            read -p "Press Enter to start cfdisk..."
            cfdisk "$disk"
            
            sleep 2
            partprobe "$disk" 2>/dev/null || true
            
            # Smart partition detection
            EFI_PART=$(lsblk -lnpo NAME,TYPE,PARTTYPE "$disk" | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print $1}' | head -1)
            if [[ -z "$EFI_PART" ]]; then
                EFI_PART=$(blkid -t TYPE=vfat -o device "$disk"* 2>/dev/null | head -1)
            fi
            
            ROOT_PART=$(lsblk -lnpo NAME,SIZE,TYPE "$disk" | grep part | grep -v "$(basename "$EFI_PART")" | sort -k2 -h | tail -1 | awk '{print $1}')
            
            if [[ -z "$ROOT_PART" ]]; then
                echo -e "${RED}Error: Could not detect root partition.${NC}" >&2
                exit 1
            fi
            ;;
    esac
    
    # NVMe partition naming fix (nvme0n1p1 vs sda1)
    if [[ "$disk" == *"nvme"* ]] && [[ "$EFI_PART" == "${disk}1" ]]; then
         EFI_PART="${disk}p1"
         ROOT_PART="${disk}p2"
    fi

    # Format
    if [[ -n "$EFI_PART" ]]; then
        mkfs.fat -F32 "$EFI_PART" || { echo -e "${RED}Format EFI failed${NC}"; exit 1; }
    fi
    mkfs.btrfs -f "$ROOT_PART" || { echo -e "${RED}Format Root failed${NC}"; exit 1; }
    
    # Subvolumes
    mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@tmp
    umount /mnt
    
    # Mount
    mount -o subvol=@,compress=zstd:1,noatime "$ROOT_PART" /mnt
    mkdir -p /mnt/{home,var,tmp,.snapshots,boot/efi}
    mount -o subvol=@home,compress=zstd:1,noatime "$ROOT_PART" /mnt/home
    mount -o subvol=@var,compress=zstd:1,noatime "$ROOT_PART" /mnt/var
    mount -o subvol=@tmp,compress=zstd:1,noatime "$ROOT_PART" /mnt/tmp
    mount -o subvol=@snapshots,compress=zstd:1,noatime "$ROOT_PART" /mnt/.snapshots
    
    if [[ -n "$EFI_PART" ]]; then
        mount "$EFI_PART" /mnt/boot/efi
    fi
}

# Configure mirror using reflector
echo -e "${GREEN}Configuring fast mirrors (Reflector)...${NC}"
if ! command -v reflector >/dev/null 2>&1; then
    pacman -S --noconfirm reflector 2>/dev/null || echo -e "${YELLOW}Warning: Could not install reflector${NC}"
fi

cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

# REFLECTOR OPTIMIZATION: 
# 1. --download-timeout 5: Skips dead mirrors quickly
# 2. --latest 20: Ensures freshness
# 3. --sort rate: Ensures speed
if command -v reflector >/dev/null 2>&1; then
    if [[ -n "$MIRROR_COUNTRIES" ]]; then
        reflector --country "$MIRROR_COUNTRIES" \
                  --age 12 --protocol https --ipv4 \
                  --latest 20 --sort rate --save /etc/pacman.d/mirrorlist \
                  --download-timeout 5 --verbose || {
            echo -e "${YELLOW}Reflector failed for specific countries, falling back to global...${NC}"
            reflector --age 12 --protocol https --ipv4 \
                      --latest 20 --sort rate --save /etc/pacman.d/mirrorlist \
                      --download-timeout 5
        }
    else
        reflector --age 12 --protocol https --ipv4 \
                  --latest 20 --sort rate --save /etc/pacman.d/mirrorlist \
                  --download-timeout 5 --verbose
    fi
fi

# Force sync after new mirrorlist
pacman -Syy

# Partition disk
partition_disk "$DISK_PATH" "$PARTITION_METHOD"

# Install base system
# Parallel downloads are now ACTIVE in the live environment, making this part fast
echo -e "${GREEN}Installing base system (fast mode)...${NC}"
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs

# Copy the optimized mirrorlist to the new system so it stays fast
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# Configure target pacman.conf
echo -e "${GREEN}Configuring target system pacman...${NC}"
if [[ -f /mnt/etc/pacman.conf ]]; then
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /mnt/etc/pacman.conf
    sed -i 's/^#Color/Color/' /mnt/etc/pacman.conf
fi

# Generate fstab
echo -e "${GREEN}Generating fstab...${NC}"
genfstab -U /mnt >> /mnt/etc/fstab

# Configure zram swap
echo -e "${GREEN}Configuring zram swap...${NC}"
arch-chroot /mnt pacman -S --noconfirm systemd-zram-generator
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
arch-chroot /mnt systemctl enable systemd-zram-setup@zram0.service

# Install GPU drivers
echo -e "${GREEN}Installing GPU drivers...${NC}"
case "$GPU_CHOICE" in
    "Intel")
        arch-chroot /mnt pacman -S --noconfirm mesa vulkan-intel intel-media-driver libva-intel-driver intel-gpu-tools ;;
    "AMD")
        arch-chroot /mnt pacman -S --noconfirm mesa vulkan-radeon libva-mesa-driver ;;
    "NVIDIA (newer)")
        arch-chroot /mnt pacman -S --noconfirm nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings ;;
    "NVIDIA (older)")
        arch-chroot /mnt pacman -S --noconfirm nvidia nvidia-utils lib32-nvidia-utils nvidia-settings ;;
esac

# Install NetworkManager
echo -e "${GREEN}Installing NetworkManager...${NC}"
arch-chroot /mnt pacman -S --noconfirm networkmanager network-manager-applet nm-connection-editor

if [[ "$INSTALL_CUPS" == "true" ]]; then
    echo -e "${GREEN}Installing CUPS...${NC}"
    arch-chroot /mnt pacman -S --noconfirm cups cups-pdf
    arch-chroot /mnt systemctl enable cups.service
fi

# Configure system
echo -e "${GREEN}Configuring system internals...${NC}"
arch-chroot /mnt ln -sf /usr/share/zoneinfo/UTC /etc/localtime
arch-chroot /mnt hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "archlinux" > /mnt/etc/hostname

cat > /mnt/etc/hosts <<EOF
127.0.0.1    localhost
::1          localhost
127.0.1.1    archlinux.localdomain    archlinux
EOF

# Create user
echo -e "${GREEN}Creating user accounts...${NC}"
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | arch-chroot /mnt chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /mnt/etc/sudoers

if [[ "$LOCK_ROOT" == "true" ]]; then
    arch-chroot /mnt passwd -l root
else
    echo "root:$ROOT_PASSWORD" | arch-chroot /mnt chpasswd
fi

arch-chroot /mnt systemctl enable NetworkManager.service

# Install bootloader
echo -e "${GREEN}Installing bootloader...${NC}"
arch-chroot /mnt pacman -S --noconfirm grub efibootmgr
if [[ -n "$EFI_PART" ]] && [[ -e "$EFI_PART" ]]; then
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
    echo -e "${YELLOW}Warning: BIOS/Legacy boot detected.${NC}"
    arch-chroot /mnt grub-install --target=i386-pc "$DISK_PATH"
fi
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Mkinitcpio
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems btrfs fsck)/' /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -P

echo -e "\n${GREEN}=== Installation Complete! ===${NC}"
echo "You can now reboot into your new Arch Linux installation."
echo "1. Unmount: umount -R /mnt"
echo "2. Reboot: reboot"
