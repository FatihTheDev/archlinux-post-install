#!/bin/bash
set -euo pipefail

# Identify the actual user who called the script
# Use $USER if logname fails (e.g., in chroot environment)
REAL_USER=$(logname 2>/dev/null || echo "$USER")
# When run from installation.sh (inside arch-chroot), we're root and logname fails:
# use the first normal user (UID >= 1000) created by the installer
if [[ "$REAL_USER" == "root" ]]; then
    FIRST_NORMAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
    if [[ -n "$FIRST_NORMAL_USER" ]]; then
        REAL_USER="$FIRST_NORMAL_USER"
    fi
fi
SUDOERS_FILE="/etc/sudoers.d/post-install-automation"

# Grant temporary NOPASSWD privilege for the entire session (if not already granted)
if ! sudo grep -q "^$REAL_USER.*NOPASSWD" /etc/sudoers.d/post-install-temp 2>/dev/null; then
    echo "Granting temporary passwordless sudo to $REAL_USER..."
    echo "$REAL_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee "$SUDOERS_FILE" > /dev/null
else
    echo "Passwordless sudo already configured for $REAL_USER"
fi

# Set a trap to delete the file on exit (success or failure)
trap "sudo rm -f $SUDOERS_FILE; echo 'Temporary sudo privileges removed.'" EXIT

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

### 4. Install yay-bin (AUR helper) ###
echo "Installing yay..."
sudo pacman -S --noconfirm yay


### 5. Install JetBrains Mono Nerd Font ###
echo "Downloading and installing JetBrains Mono Nerd Font (Regular)..."
sudo pacman -S ttf-jetbrains-mono-nerd

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

USER_NAME=$REAL_USER
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
ZSHRC="$USER_HOME/.zshrc"

# Install Oh-My-Zsh unattended (runuser works in chroot where sudo -u can fail)
runuser -u "$USER_NAME" -- sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Ensure .config exists
mkdir -p "$USER_HOME/.config"
chown -R "$USER_NAME":"$(id -gn "$USER_NAME")" "$USER_HOME/.config"

# Add zsh-syntax-highlighting
echo "source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" | tee -a "$ZSHRC"

# Add Starship init
echo 'eval "$(starship init zsh)"' >> "$ZSHRC"

# Aliases
echo 'alias ll="ls -l"' | tee -a "$ZSHRC"
echo 'alias la="ls -a"' | tee -a "$ZSHRC"
echo 'alias l="ls -la"' | tee -a "$ZSHRC"
echo '' | tee -a "$ZSHRC"

echo "alias removeall='f() { sudo pacman -Rcns \$(pacman -Qq | grep \"\$1\"); }; f'" | tee -a "$ZSHRC"
echo "alias update-grub='sudo grub-mkconfig -o /boot/grub/grub.cfg'" | tee -a "$ZSHRC"
echo '' | tee -a "$ZSHRC"

echo '# Mirror countries: SE - Sweden, FR - France, DE - Germany, US - United States (if you use just 1 country, no need for quotation marks and backslashes)' | tee -a "$ZSHRC"
echo 'alias update-mirrors="sudo reflector --country \"SE, FR\" --latest 7 --sort rate --fastest 5 --protocol https --save /etc/pacman.d/mirrorlist"' | tee -a "$ZSHRC"
echo '' | tee -a "$ZSHRC"

echo '# Disable sleep when AUR package is being built' | tee -a "$ZSHRC"
echo 'alias yay="systemd-inhibit --what=sleep --who=yay --why=\"AUR build in progress\" yay"' | tee -a "$ZSHRC"  

echo '# Remove selected files' | tee -a "$ZSHRC"
echo 'removefiles() {
  local pattern="$1" dir selected

  [[ -z "$pattern" ]] && {
    echo "Usage: removefiles <pattern>"
    return 1
  }

  read "choice?Search (1) Root (2) Custom: "
  case "$choice" in
    2)
      dir=$(find / -maxdepth 3 -type d 2>/dev/null |
            fzf --height 70% --border)
      dir="${dir:-/}"
      ;;
    *) dir="/" ;;
  esac

  selected=$(
    fd -HI --absolute-path -t f -t d "$pattern" "$dir" 2>/dev/null |
      fzf --multi \
          --height 70% \
          --bind "tab:toggle" \
          --border \
          --prompt="Select> " \
          --header="TAB = select/unselect | ENTER = confirm | ESC = cancel"
  )

  [[ -z "$selected" ]] && {
    echo "No files selected."
    return 0
  }

  echo
  echo "The following items will be deleted:"
  echo "------------------------------------"
  printf '%s\n' "$selected"
  echo "------------------------------------"

  read "confirm?Proceed with deletion? [y/N]: "
  [[ "$confirm" != [yY] ]] && {
    echo "Aborted."
    return 0
  }

  printf '%s\n' "$selected" | sudo xargs -r rm -rf

  echo "Bulk deletion complete."
}' | tee -a "$ZSHRC"
echo '' | tee -a "$ZSHRC"

echo '# Search files with fd' | tee -a "$ZSHRC"
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
}' | tee -a "$ZSHRC"
echo '' | tee -a "$ZSHRC"

echo '# Pin a package (add to IgnorePkg)' | tee -a "$ZSHRC"
echo 'pin() {
    sudo grep -q "^IgnorePkg" /etc/pacman.conf || echo "IgnorePkg =" | sudo tee -a /etc/pacman.conf >/dev/null
    comm -23 <(pacman -Qq | sort) <(grep "^IgnorePkg" /etc/pacman.conf | cut -d= -f2 | tr " " "\n" | sort -u | sed "/^$/d") | \
    fzf --prompt="Pin: " --height=70% --border | \
    while read -r pkg; do
        sudo sed -i "/^IgnorePkg/ s/$/ $pkg/" /etc/pacman.conf
        sudo sed -i "/^IgnorePkg/ s/[[:space:]]\+/ /g" /etc/pacman.conf
        echo "Pinned: $pkg"
    done
}' | tee -a "$ZSHRC"
echo '' | tee -a "$ZSHRC"
echo '# Unpin a package (remove from IgnorePkg)' | tee -a "$ZSHRC"
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
}' | tee -a "$ZSHRC"
echo '' | tee -a "$ZSHRC"

echo 'source ~/.local/bin/theme-env.sh' | tee -a "$ZSHRC"
echo '' | tee -a "$ZSHRC"

# For theme customizations
echo '#For theming the syntax highlighting' | tee -a "$ZSHRC"
echo '[ -f ~/.config/zsh_theme_sync ] && source ~/.config/zsh_theme_sync' | tee -a "$ZSHRC"

# Set default shell to zsh
chsh -s /bin/zsh "$USER_NAME"

# Fix permissions (run as root, no sudo -u)
chown -R "$USER_NAME":"$(id -gn "$USER_NAME")" "$USER_HOME/.zshrc" "$USER_HOME/.oh-my-zsh" "$USER_HOME/.config" 2>/dev/null || true

# Disabling starship timeout warnings
mkdir -p "$USER_HOME/.config"
cat <<'EOF' > "$USER_HOME/.config/starship.toml"
# Disable timeout warnings by setting a very high value (in milliseconds)
scan_timeout = 10000
EOF
chown "$USER_NAME":"$(id -gn "$USER_NAME")" "$USER_HOME/.config/starship.toml"


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
    echo "Installing virtualization packages..."
    sudo pacman -S --noconfirm libvirt virt-manager qemu-desktop dnsmasq dmidecode

    echo "Enabling virtualization services..."
    sudo systemctl enable --now libvirtd.service virtlogd.service

    echo "Adding user to libvirt and kvm groups..."
    sudo usermod -aG libvirt "$REAL_USER"
    sudo usermod -aG kvm "$REAL_USER"

    echo "Autostarting default libvirt network..."
    sudo virsh net-autostart default
    

echo "All tasks completed successfully! Please reboot to apply all changes."
