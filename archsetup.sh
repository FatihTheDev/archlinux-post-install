#!/bin/bash
set -euo pipefail

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

cp /usr/lib/systemd/system/grub-btrfsd.service /etc/systemd/system/grub-btrfsd.service
sed -i 's|ExecStart=.*|ExecStart=/usr/bin/grub-btrfsd --timeshift-auto|' /etc/systemd/system/grub-btrfsd.service

sudo systemctl daemon-reload
sudo systemctl enable --now grub-btrfsd.service

echo "Updating grub..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

### 2. Install reflector and configure fastest global mirrors (balanced) ###
echo "Installing reflector..."
sudo pacman -S --noconfirm reflector curl

REFLECTOR_OVERRIDE_DIR="/etc/systemd/system/reflector.service.d"
sudo mkdir -p "$REFLECTOR_OVERRIDE_DIR"
cat <<EOF | sudo tee "$REFLECTOR_OVERRIDE_DIR/override.conf"
[Service]
ExecStart=
ExecStart=/usr/bin/reflector --latest 10 --sort rate --fastest 5 --save /etc/pacman.d/mirrorlist
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now reflector.service

### 3. Add Chaotic AUR ###
echo "Adding Chaotic AUR..."
sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign-key 3056513887B78AEB
sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
    cat <<'EOF' | sudo tee -a /etc/pacman.conf

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
fi

### 4. Install yay-bin from source ###
echo "Installing yay-bin..."
if ! command -v git &> /dev/null; then
    sudo pacman -S --noconfirm git base-devel
fi

sudo -u $(logname) bash <<'EOF'
cd /tmp
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si --noconfirm
EOF

### 5. Prompt for Zsh and customizations ###
if ask_yn "Do you want to install Zsh with Oh-My-Zsh, Starship, and syntax highlighting?"; then
    echo "Installing zsh, oh-my-zsh, starship..."
    sudo pacman -S --noconfirm zsh starship zsh-syntax-highlighting

    USER_NAME=$(logname)
    USER_HOME=$(eval echo ~"$USER_NAME")
    ZSHRC="$USER_HOME/.zshrc"

    sudo -u "$USER_NAME" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    sudo -u "$USER_NAME" mkdir -p "$USER_HOME/.config"
    sudo -u "$USER_NAME" sh -c "echo 'eval \"\$(starship init zsh)\"' >> \"$ZSHRC\""

    echo "source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" | sudo tee -a "$ZSHRC"
    echo "alias removeall='f() { sudo pacman -Rns \$(pacman -Qq | grep \"^\$1\"); }; f'" | sudo tee -a "$ZSHRC"

    chsh -s /bin/zsh "$USER_NAME"
    sudo chown "$USER_NAME":"$(id -gn "$USER_NAME")" "$ZSHRC"
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
    sudo usermod -aG libvirt $(logname)

    echo "Autostarting default libvirt network..."
    sudo virsh net-autostart default
fi

### 7. Prompt for VLC and KDE Connect ###
if ask_yn "Do you want to install VLC media player?"; then
    sudo pacman -S --noconfirm vlc
fi

if ask_yn "Do you want to install KDE Connect?"; then
    sudo pacman -S --noconfirm kdeconnect
fi

### 8. Kernel headers installation ###
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

echo "All tasks completed successfully! Please reboot to apply all changes."
