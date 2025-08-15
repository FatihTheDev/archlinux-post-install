#!/bin/bash
set -euo pipefail

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root (use sudo)."
    exit 1
fi

# Detect the real non-root user who invoked sudo
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER=$(logname 2>/dev/null || echo "$USER")
fi

REAL_HOME=$(eval echo "~$REAL_USER")

echo "Updating system..."
pacman -Syu --noconfirm

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
pacman -S --noconfirm grub-btrfs

GRUB_BTRFS_OVERRIDE_DIR="/etc/systemd/system/grub-btrfsd.service.d"
mkdir -p "$GRUB_BTRFS_OVERRIDE_DIR"
cat > "$GRUB_BTRFS_OVERRIDE_DIR/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --timeshift-auto
EOF

systemctl daemon-reload
systemctl enable --now grub-btrfsd.service

echo "Updating grub..."
grub-mkconfig -o /boot/grub/grub.cfg

### 2. Install reflector and configure fastest global mirrors (balanced) ###
echo "Installing reflector..."
pacman -S --noconfirm reflector curl

REFLECTOR_OVERRIDE_DIR="/etc/systemd/system/reflector.service.d"
mkdir -p "$REFLECTOR_OVERRIDE_DIR"
cat > "$REFLECTOR_OVERRIDE_DIR/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/reflector --latest 15 --sort rate --fastest 5 --save /etc/pacman.d/mirrorlist
EOF

systemctl daemon-reload
systemctl enable --now reflector.service

### 3. Add Chaotic AUR ###
echo "Adding Chaotic AUR..."
pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
pacman-key --lsign-key 3056513887B78AEB
pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

echo "Refreshing repositories..."
pacman -Sy

if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<'EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
fi

### 4. Install yay-bin from source ###
echo "Installing yay-bin..."
if ! command -v git &> /dev/null; then
    pacman -S --noconfirm git base-devel
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
    pacman -S --noconfirm zsh starship zsh-syntax-highlighting

    ZSHRC="$REAL_HOME/.zshrc"

    # Install oh-my-zsh for the user (unattended)
    sudo -u "$REAL_USER" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

    # Configure starship prompt for zsh
    sudo -u "$REAL_USER" mkdir -p "$REAL_HOME/.config"
    sudo -u "$REAL_USER" sh -c "echo 'eval \"\$(starship init zsh)\"' >> \"$ZSHRC\""

    # Enable zsh syntax highlighting
    echo "source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> "$ZSHRC"

    # Add removeall alias
    echo "alias removeall='f() { sudo pacman -Rns \$(pacman -Qq | grep \"^\$1\"); }; f'" >> "$ZSHRC"

    # Make zsh the default shell for the user
    chsh -s /bin/zsh "$REAL_USER"

    chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$ZSHRC"
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
    pacman -S --noconfirm libvirt virt-manager "$qemu_pkg" dnsmasq dmidecode

    echo "Enabling virtualization services..."
    systemctl enable --now libvirtd.service virtlogd.service

    echo "Adding user to libvirt group..."
    usermod -aG libvirt "$REAL_USER"

    echo "Autostarting default libvirt network..."
    virsh net-autostart default
fi

### 7. Prompt for VLC and KDE Connect ###
if ask_yn "Do you want to install VLC media player?"; then
    pacman -S --noconfirm vlc
fi

if ask_yn "Do you want to install KDE Connect?"; then
    pacman -S --noconfirm kdeconnect
fi

echo "All tasks completed successfully! Please reboot to apply all changes."
