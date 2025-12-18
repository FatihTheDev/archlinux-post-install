#!/bin/bash
set -euo pipefail

echo "Updating system..."
sudo pacman -Syu --noconfirm

### Helper function for yes/no prompt ###
ask_yn() {
    local prompt="$1"
    local response
    while true; do
        read -rp "$prompt [y/n]: " response < /dev/tty
        case "$response" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "Please enter y or n." ;;
        esac
    done
}

### 0. Installing basic tools ###
echo "Installing basic system tools..."
sudo pacman -S --noconfirm man unzip tldr flatpak

### 1. Install grub-btrfs with Timeshift support ###
echo "Installing grub-btrfs..."
sudo pacman -S --noconfirm timeshift grub-btrfs

echo "Configuring grub-btrfsd to use Timeshift..."
sudo cp /usr/lib/systemd/system/grub-btrfsd.service /etc/systemd/system/grub-btrfsd.service
sudo sed -i 's|ExecStart=.*|ExecStart=/usr/bin/grub-btrfsd --syslog --timeshift-auto|' /etc/systemd/system/grub-btrfsd.service

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
ExecStart=/usr/bin/reflector --latest 7 --sort rate --fastest 5 --protocol https --save /etc/pacman.d/mirrorlist
EOF

sudo systemctl daemon-reload
# sudo systemctl enable --now reflector.timer
# sudo systemctl enable --now reflector.service

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

echo "Refreshing system repositories..."
sudo pacman -Sy

### 4. Install yay-bin (AUR helper) from source ###
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


### 5. Install JetBrains Mono Nerd Font ###
echo "Downloading and installing JetBrains Mono Nerd Font (Regular)..."
    
USER_NAME=$(logname)

sudo -u "$USER_NAME" bash <<'EOF'
mkdir -p ~/.local/share/fonts/nerd-fonts
cd /tmp
curl -LO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
unzip -j -o JetBrainsMono.zip "JetBrainsMonoNerdFont-Regular.ttf" -d ~/.local/share/fonts/nerd-fonts/
fc-cache -fv
EOF

echo "JetBrains Mono Nerd Font (Regular) installed successfully!"

### 6. Modify /etc/pacman.conf and /etc/makepkg.conf to enable parallel downloads and parallel compilation ###
echo "Enabling parallel downloads and parallel compilation..."
# Uncommenting parallel downloads in /etc/pacman.conf
sudo sed -i 's/^#\s*\(ParallelDownloads\s*=\s*[0-9]*\)/\1/' /etc/pacman.conf
# Uncommenting MAKEFLAGS to use number of threads available on device in /etc/makepkg.conf
threads=$(nproc --all)
sudo awk -v threads="$threads" '
/^#\s*MAKEFLAGS=/ { sub(/#.*/, "MAKEFLAGS=\"-j" threads "\""); found=1 }
/^MAKEFLAGS=/ { sub(/=.*/, "=\"-j" threads "\""); found=1 }
{ print }
END {
    if (!found) print "MAKEFLAGS=\"-j" threads "\""
}
' /etc/makepkg.conf > /tmp/makepkg.conf && sudo mv /tmp/makepkg.conf /etc/makepkg.conf 

# Uncommenting IgnorePkg in /etc/pacman.conf to make pin and unpin aliases work properly
sudo sed -i 's/^#\s*IgnorePkg\s*=/IgnorePkg =/' /etc/pacman.conf
# If IgnorePkg still doesn't exist at all under [options], add it once
if ! grep -q "^IgnorePkg\s*=" /etc/pacman.conf; then
    sudo sed -i '/^\[options\]/a IgnorePkg =' /etc/pacman.conf
fi


### 7. Install Zsh and customizations ###
echo "Installing zsh, oh-my-zsh, starship..."
sudo pacman -S --noconfirm zsh starship zsh-syntax-highlighting

USER_NAME=$(logname)
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
ZSHRC="$USER_HOME/.zshrc"

# Install Oh-My-Zsh unattended
sudo -u "$USER_NAME" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Ensure .config exists
sudo -u "$USER_NAME" mkdir -p "$USER_HOME/.config"

# Add zsh-syntax-highlighting
echo "source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" | sudo tee -a "$ZSHRC"

# Add Starship init
sudo -u "$USER_NAME" sh -c "echo 'eval \"\$(starship init zsh)\"' >> \"$ZSHRC\""

# Aliases
echo 'alias ll="ls -l"' | sudo tee -a "$ZSHRC"
echo 'alias la="ls -a"' | sudo tee -a "$ZSHRC"
echo 'alias l="ls -la"' | sudo tee -a "$ZSHRC"
echo '' | sudo tee -a "$ZSHRC"

echo "alias removeall='f() { sudo pacman -Rcns \$(pacman -Qq | grep \"\$1\"); }; f'" | sudo tee -a "$ZSHRC"
echo "alias update-grub='sudo grub-mkconfig -o /boot/grub/grub.cfg'" | sudo tee -a "$ZSHRC"
echo '' | sudo tee -a "$ZSHRC"

echo '# Mirror countries: SE - Sweden, FR - France, DE - Germany, US - United States (you can remove the backslashes)' | sudo tee -a "$ZSHRC"
echo 'alias update-mirrors="sudo reflector --country \"SE, FR\" --latest 7 --sort rate --fastest 5 --protocol https --save /etc/pacman.d/mirrorlist"' | sudo tee -a "$ZSHRC"
echo '' | sudo tee -a "$ZSHRC"

echo '# Remove selected files' | sudo tee -a "$ZSHRC"
echo 'removefiles() {
  local pattern="\$1" dir selected
  if [[ -z "\$pattern" ]]; then
    echo "Usage: removefiles <pattern>"
    return 1
  fi
  echo "Delete from:"
  echo "1) Root directory (/)"
  echo "2) Specific directory (choose with fzf)"
  read "choice?Choice (1/2): "
  case "\$choice" in
    2)
      dir=$(find / -type d -maxdepth 3 2>/dev/null | fzf --prompt="Select directory: " --height=50%)
      dir="\${dir:-/}"
      ;;
    1|"") dir="/" ;;
    *) echo "Invalid choice. Using root."; dir="/" ;;
  esac
  while true; do
    files=$(fd -HI --absolute-path "\$pattern" "\$dir")
    [[ -z "\$files" ]] && { echo "No matching files left."; break; }
    selected=$(printf "%s\n" "\$files" | fzf --prompt="Select a file to delete (Esc to exit): " --height=70% --ansi)
    [[ -z "\$selected" ]] && break
    if sudo rm "\$selected"; then
      echo "removed \$selected"
    else
      echo "Failed to remove \$selected"
    fi
  done
}' | sudo tee -a "$ZSHRC"
echo '' | sudo tee -a "$ZSHRC"

echo '# Search files with fd' | sudo tee -a "$ZSHRC"
echo 'search() {
  local pattern="$1" dir
  if [[ -z "$pattern" ]]; then
    echo "Usage: search <pattern>"
    return 1
  fi
  echo "Search from:"
  echo "1) Root directory (/)"
  echo "2) Specific directory (choose with fzf)"
  read "choice?Choice (1/2): "
  case "$choice" in
    2)
      dir=$(find / -type d -maxdepth 3 2>/dev/null | fzf --prompt="Select directory: " --height=50%)
      dir="${dir:-/}"
      ;;
    1|"") dir="/" ;;
    *) echo "Invalid choice. Using root."; dir="/" ;;
  esac
  echo "Searching for \"$pattern\" in $dir..."
  fd -HI --absolute-path "$pattern" "$dir" 2>/dev/null
}' | sudo tee -a "$ZSHRC"
echo '' | sudo tee -a "$ZSHRC"

echo '# Pin a package (add to IgnorePkg)' | sudo tee -a "$ZSHRC"
echo 'pin() {
    sudo grep -q "^IgnorePkg" /etc/pacman.conf || echo "IgnorePkg =" | sudo tee -a /etc/pacman.conf >/dev/null
    comm -23 <(pacman -Qq | sort) <(grep "^IgnorePkg" /etc/pacman.conf | cut -d= -f2 | tr " " "\n" | sort -u | sed "/^$/d") | \
    fzf --prompt="Pin: " --height=70% --border | \
    while read -r pkg; do
        sudo sed -i "/^IgnorePkg/ s/$/ $pkg/" /etc/pacman.conf
        sudo sed -i "/^IgnorePkg/ s/[[:space:]]\+/ /g" /etc/pacman.conf
        echo "Pinned: $pkg"
    done
}' | sudo tee -a "$ZSHRC"
echo '' | sudo tee -a "$ZSHRC"
echo '# Unpin a package (remove from IgnorePkg)' | sudo tee -a "$ZSHRC"
echo 'unpin() {
    grep "^IgnorePkg" /etc/pacman.conf | cut -d= -f2 | tr " " "\n" | sed "/^$/d" | \
    fzf --prompt="Unpin: " --height=70% --border --multi | \
    while read -r pkg; do
        escaped_pkg=$(printf "%s\n" "$pkg" | sed "s/[.[\*^$]/\\\\&/g")
        sudo sed -i "/^IgnorePkg/ s/[[:space:]]$escaped_pkg//g" /etc/pacman.conf
        sudo sed -i "/^IgnorePkg/ s/[[:space:]]\+/ /g" /etc/pacman.conf
        sudo sed -i "/^IgnorePkg[[:space:]]*=/ s/$//" /etc/pacman.conf
        echo "Unpinned: $pkg"
    done
    sudo sed -i "s/^IgnorePkg[[:space:]]*=[[:space:]]*$/IgnorePkg =/" /etc/pacman.conf
}' | sudo tee -a "$ZSHRC"
echo '' | sudo tee -a "$ZSHRC"

# For theme customizations
echo '#For theming the syntax highlighting' | sudo tee -a "$ZSHRC"
echo '[ -f ~/.config/zsh_syntax_theme ] && source ~/.config/zsh_syntax_theme' | sudo tee -a "$ZSHRC"

# Set default shell to zsh
sudo chsh -s /bin/zsh "$USER_NAME"

# Fix permissions
sudo chown "$USER_NAME":"$(id -gn "$USER_NAME")" "$ZSHRC"


### 8. Kernel headers installation ###
current_kernel=$(uname -r)
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


### 9. Virtualization setup ###
    while true; do
        read -rp "Do you want 'qemu-full' or 'qemu-desktop'? [full/desktop]: " qemu_choice < /dev/tty
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

    echo "Adding user to libvirt and kvm groups..."
    sudo usermod -aG libvirt $(logname)
    sudo usermod -aG kvm $(logname)

    echo "Autostarting default libvirt network..."
    sudo virsh net-autostart default
    

echo "All tasks completed successfully! Please reboot to apply all changes."
