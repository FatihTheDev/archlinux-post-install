# archlinux-post-install
- This is a shell script for configuring grub-btrfs with timeshift, installing zsh and configuring handy aliases and other useful utilities for Arch Linux.
- **Note**: This is a post-install script, meaning that you already need to have Arch installed with proper **btrfs subvolumes for Timeshift**, as well as **Timeshift** itself, because this script does NOT install GPU drivers and base packages. You can use **archinstall** script to make installing Arch Linux easier.

- To run this script, use wget (install using sudo pacman -S wget):
```wget -qO - https://raw.githubusercontent.com/FatihTheDev/archlinux-post-install/main/archsetup.sh | bash```
