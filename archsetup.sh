#!/bin/bash
set -euo pipefail

# Detect the real non-root user
REAL_USER=$(logname 2>/dev/null || echo "$USER")
REAL_HOME=$(eval echo "~$REAL_USER")

echo "Updating system..."
sudo pacman -Syu --noconfirm

### Helper function for yes/no prompt ###
ask_yn() {
    local prompt="$1"
    local response
    while true; do
        read -rp "$prompt [y/n]: " response
        case "$response" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "Please enter y or n." ;;
        esac
    done
}

### 1. Install grub-btrfs with Timeshift support ###
echo "Installing grub-btrfs..."
sudo pacman -S --noconfirm grub-btrfs

# Replace systemd service file fully to use Timeshift
echo "Configuring grub-btrfsd to use Timeshift..."
cp /usr/lib/systemd/system/grub-btrfsd.service /etc/systemd/system/grub-btrfsd.service
sed -i 's|ExecStart=.*|ExecStart=/usr/bin/grub-btrfsd --syslog --timeshift-auto|' /etc/systemd/system/grub-btrfsd.service

sudo systemctl daemon-reload
sudo systemctl enable --now grub-btrfsd.service

echo "Updating grub..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

### 2. Install reflector and configure fastest global mirrors (balanced) ###
echo "Installing reflector..."
sudo pacman -S --noconfirm reflector curl

REFLECTOR_OVERRIDE_DIR="/etc/systemd/system/reflector.service.d"
sudo mkdir -p "$REFLECTOR_OVERRIDE_DIR"
sudo tee "$REFLECTOR_OVERRIDE_DIR/override.conf" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/reflector --latest 10 --sort rate --fastest 5 --save /etc/pacman.d/mirrorlist
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now reflector.timer
sudo systemctl enable --now reflector.service

### 3. Add Chaotic AUR ###
echo "Adding Chaotic AUR..."
sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign-key 3056513887B78AEB
sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
    sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
fi

echo "Refreshing repositories..."
sudo pacman -Sy

### 4. Install yay-bin from source ###
echo "Installing yay-bin..."
if ! command -v git &> /dev/null; then
    sudo pacman -S --noconfirm git base-devel
fi

sudo -u "$REAL_USER" bash <<'EOF'
cd /tmp
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si --noconfirm
EOF

### 5. Prompt for Zsh and customizations ###
if ask_yn "Do you want to install Zsh with Oh-My-Zsh, Starship, and syntax highlighting?"; then
    echo "Installing zsh, oh-my-zsh, starship..."
    sudo pacman -S --noconfirm zsh starship zsh-syntax-highlighting

    ZSHRC="$REAL_HOME/.zshrc"

    sudo -u "$REAL_USER" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

    sudo -u "$REAL_USER" mkdir -p "$REAL_HOME/.config"
    sudo -u "$REAL_USER" sh -c "echo 'eval \"\$(starship init zsh)\"' >> \"$ZSHRC\""

    echo "source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" | sudo tee -a "$ZSHRC" >/dev/null
    echo "alias removeall='f() { sudo pacman -Rns \$(pacman -Qq | grep \"^\$1\"); }; f'" | sudo tee -a "$ZSHRC" >/dev/null

    sudo chsh -s /bin/zsh "$REAL_USER"
    sudo chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$ZSHRC"
fi

### 6. Prompt for virtualization setup ###
if ask_yn "Do you want to install virtualization support (libvirt, virt-manager, QEMU)?"; then
    while true; do
        read -rp "Do you want 'qemu-full' or 'qemu-desktop'? [full/desktop]: " qemu_choice
        case "$qemu_choice" in
            full) qemu_pkg="qemu-full"; break ;;
            desktop) qemu_pkg="qemu-desktop"; break ;;
            *) echo "Please enter 'full' or 'desktop'." ;;
        esac
    done

    echo "Installing virtualization packages..."
    sudo pacman -S --noconfirm libvirt virt-manager "$qemu_pkg" dnsmasq dmidecode

    echo "Enabling virtualization services..."
    sudo systemctl enable --now libvirtd.service virtlogd.service

    echo "Adding user to libvirt group..."
    sudo usermod -aG libvirt "$REAL_USER"

    echo "Autostarting default libvirt network..."
    sudo virsh net-autostart default
fi

### 7. Kernel headers installation ###
if ask_yn "Do you want to install kernel headers? (Needed for building kernel modules like VirtualBox, NVIDIA drivers, ZFS, etc.)"; then
    current_kernel=$(uname -r)
    base_kernel=$(echo "$current_kernel" | cut -d'-' -f1)
    suffix=$(echo "$current_kernel" | cut -d'-' -f2-)

    if [[ "$suffix" == *"arch"* ]]; then
        sudo pacman -S --noconfirm linux-headers
    elif [[ "$suffix" == *"lts"* ]]; then
        sudo pacman -S --noconfirm linux-lts-headers
    elif [[ "$suffix" == *"zen"* ]]; then
        sudo pacman -S --noconfirm linux-zen-headers
    elif [[ "$suffix" == *"hardened"* ]]; then
        sudo pacman -S --noconfirm linux-hardened-headers
    else
        echo "⚠ Could not automatically determine headers for kernel: $current_kernel"
        echo "You may need to install them manually (e.g. linux-headers, linux-lts-headers)."
    fi
fi

### 8. Gaming tweaks (CachyOS kernel, gaming meta packages, Proton-GE) ###
echo "Adding CachyOS repositories..."
sudo pacman-key --recv-key FBA220DFC880C036 --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign-key FBA220DFC880C036
sudo pacman -U --noconfirm 'https://mirror.cachyos.org/cachyos/cachyos-keyring.pkg.tar.zst'
sudo pacman -U --noconfirm 'https://mirror.cachyos.org/cachyos/cachyos-mirrorlist.pkg.tar.zst'

if ! grep -q "\[cachyos\]" /etc/pacman.conf; then
    cat <<'EOF' | sudo tee -a /etc/pacman.conf

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF
fi

echo "Refreshing repositories..."
sudo pacman -Sy

echo "Installing CachyOS kernel and gaming packages..."
sudo pacman -S --noconfirm linux-cachyos linux-cachyos-headers cachyos-settings cachyos-gaming-meta

echo "Installing Proton-GE (Chaotic AUR)..."
sudo pacman -S --noconfirm proton-ge-custom-bin

### 9. Prompt for VLC and KDE Connect ###
if ask_yn "Do you want to install VLC media player?"; then
    sudo pacman -S --noconfirm vlc
fi

if ask_yn "Do you want to install KDE Connect?"; then
    sudo pacman -S --noconfirm kdeconnect
fi

echo "All tasks completed successfully! Please reboot to apply all changes."
