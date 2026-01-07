#!/bin/bash

# Define Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== Archinstall Auto-Wrapper ===${NC}"
echo -e "${GREEN}Updating archinstall to latest version...${NC}"
pip install --upgrade archinstall &>/dev/null

# ----------------------------------
# 1. GATHER USER INPUTS
# ----------------------------------

# Get Credentials
echo -e "\n${BLUE}--- User Configuration ---${NC}"
read -p "Username: " USER_NAME
read -s -p "User Password: " USER_PASS
echo ""
read -s -p "Root Password: " ROOT_PASS
echo ""

# Get GPU Choice
echo -e "\n${BLUE}--- Hardware Setup ---${NC}"
echo "Select your GPU Driver:"
echo "1) AMD (mesa)"
echo "2) Intel (mesa)"
echo "3) NVIDIA (Proprietary)"
echo "4) VMware/VirtualBox"
read -p "Choice [1-4]: " GPU_CHOICE

# Map GPU choice to packages
case $GPU_CHOICE in
    1) GPU_DRIVER="amd";;
    2) GPU_DRIVER="intel";;
    3) GPU_DRIVER="nvidia";;
    4) GPU_DRIVER="all-open";; # Fallback for VMs
    *) GPU_DRIVER="all-open";;
esac

# Get Desktop Environment (Optional, but usually needed with GPU)
echo -e "\n${BLUE}--- Software Setup ---${NC}"
echo "Select Desktop Profile:"
echo "1) KDE Plasma"
echo "2) Gnome"
echo "3) Hyprland"
echo "4) Minimal (CLI only)"
read -p "Choice [1-4]: " DE_CHOICE

case $DE_CHOICE in
    1) PROFILE="desktop"; DE="kde";;
    2) PROFILE="desktop"; DE="gnome";;
    3) PROFILE="desktop"; DE="hyprland";;
    4) PROFILE="minimal"; DE="";; 
    *) PROFILE="minimal"; DE="";;
esac

# Select Disk (Critical Step)
echo -e "\n${BLUE}--- Disk Selection ---${NC}"
# Use Python to reliably list disks in a format we can parse
TARGET_DISK=$(python3 -c "
import archinstall
import json
try:
    disks = archinstall.list_drives()
    # Create a simple menu
    filtered_disks = [d for d in disks if d.size > 1] # Filter tiny partitions
    for i, disk in enumerate(filtered_disks):
        print(f'{i}) {disk.device} ({disk.size} GB)')
    
    selection = int(input('Select Target Disk Number: '))
    print(filtered_disks[selection].device)
except:
    print('')
")

if [[ -z "$TARGET_DISK" ]]; then
    echo -e "${RED}Invalid disk selection. Exiting.${NC}"
    exit 1
fi

echo -e "${GREEN}Targeting: $TARGET_DISK${NC}"
echo -e "${RED}WARNING: THIS WILL WIPE $TARGET_DISK!${NC}"
read -p "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then exit 1; fi

# ----------------------------------
# 2. GENERATE ARCHINSTALL CONFIG
# ----------------------------------
echo -e "\n${BLUE}Generating configuration...${NC}"

# We use Python to dump the JSON to ensure it handles the format correctly.
# This config enables: Btrfs (default compression), NetworkManager, Pipewire, etc.
python3 -c "
import json

config = {
    'version': '2.5.0',
    'archinstall-language': 'English',
    'keyboard-layout': 'us',
    'mirror-region': {'United States': 10, 'Germany': 10}, 
    'sys-language': 'en_US.UTF-8',
    'sys-encoding': 'UTF-8',
    'profile': {
        'path': '$PROFILE',
        'details': ['$DE'] if '$DE' else []
    },
    'dry-run': False,
    'harddrives': ['$TARGET_DISK'],
    'disk_layout': {
        'config_type': 'default_layout',
        'filesystem_type': 'btrfs'
    },
    'gfx_driver': '$GPU_DRIVER',
    'audio': 'pipewire',
    'kernels': ['linux'],
    'packages': [
        'vim', 'git', 'wget', 'neofetch', 'firefox'
    ],
    'network_config': {
        'type': 'nm'
    },
    'timezone': 'UTC',
    'ntp': True
}

# Creds are handled separately in newer archinstall versions, 
# but putting them in config is supported for silent automation.
creds = {
    '!users': [
        {
            'username': '$USER_NAME',
            'password': '$USER_PASS',
            'sudo': True
        }
    ],
    '!root_password': '$ROOT_PASS'
}

# Merge creds into config for simplicity
config.update(creds)

with open('auto_config.json', 'w') as f:
    json.dump(config, f, indent=4)
"

# ----------------------------------
# 3. RUN ARCHINSTALL
# ----------------------------------

echo -e "\n${GREEN}Starting Automated Install...${NC}"
echo "Sit back and relax. Archinstall is taking over."
echo "Logs are available at /var/log/archinstall/install.log"

# Run archinstall in silent mode using the generated config
archinstall --config auto_config.json --silent

if [[ $? -eq 0 ]]; then
    echo -e "\n${GREEN}Installation Complete!${NC}"
    # Clean up the config file containing passwords
    rm auto_config.json
    echo "You can now reboot."
else
    echo -e "\n${RED}Installation Failed. Check logs.${NC}"
fi
