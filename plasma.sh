#!/bin/bash

set -euo pipefail

# timedatectl
sudo timedatectl set-ntp true

# nmcli device wifi connect "" password ""
n=$(nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2=="802-11-wireless"{print $1; exit}')
if [ -n "$n" ]; then
    nmcli connection modify "$n" 802-11-wireless-security.key-mgmt sae
    [ "$(nmcli -g 802-11-wireless-security.key-mgmt connection show "$n")" = sae ] \
        && printf '\e[32m✔ "%s" is set to SAE (WPA3-Personal)\e[0m\n' "$n" \
        || printf '\e[31m✘ "%s" is NOT set to SAE\e[0m\n' "$n"
fi

# Full system upgrade
sudo pacman -Syu --noconfirm

# Intel Drivers
sudo pacman -S --needed --noconfirm intel-media-driver vulkan-intel

# Nvidia Driver
sudo pacman -S --needed --noconfirm git linux-cachyos-nvidia-open
# Nvidia System Config
tmp=$(mktemp -d)
git clone --depth 1 https://gitlab.com/asus-linux/nvidia-laptop-power-cfg.git "$tmp/cfg"
(cd "$tmp/cfg" && makepkg -sfi --noconfirm)
rm -rf "$tmp"
sudo systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate
sudo systemctl enable nvidia-powerd

# Audio
sudo pacman -S --needed --noconfirm pipewire pipewire-pulse pipewire-jack pipewire-alsa wireplumber
# Audio Services
systemctl --user enable pipewire pipewire-pulse wireplumber

# Fonts
sudo pacman -S --needed --noconfirm noto-fonts noto-fonts-emoji noto-fonts-extra noto-fonts-cjk ttf-jetbrains-mono-nerd

# KDE Plasma
sudo pacman -S --needed --noconfirm plasma-meta ark dolphin gwenview konsole kate tesseract-data-eng wl-clipboard
sudo systemctl enable plasmalogin

# Applications & Tools
sudo pacman -S --needed --noconfirm cachy-update brave-origin-bin easyeffects lsp-plugins-lv2 asusctl rog-control-center mpv aria2 fastfetch openssh sbctl

# mpv Configuration
mkdir -p ~/.config/mpv
cat > ~/.config/mpv/mpv.conf <<'EOF'
# Window
autofit=50%x50%
title=${media-title}
#title-bar=no
#no-border

# Audio and subtitles
alang=eng,en
slang=eng,en
volume=80
volume-max=130
sub-bold=yes

EOF

# aria2 config
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/aria2.service <<'EOF'
[Unit]
Description=Aria2 Daemon

[Service]
ExecStart=/usr/bin/aria2c
Restart=on-failure

[Install]
WantedBy=default.target
EOF
mkdir -p ~/.config/aria2
cat > ~/.config/aria2/aria2.conf << EOF
dir=${HOME}/Downloads/
input-file=${HOME}/.config/aria2/aria2.session
save-session=${HOME}/.config/aria2/aria2.session
save-session-interval=60
max-connection-per-server=16
split=16
min-split-size=5M
file-allocation=falloc
async-dns=false
continue=true
enable-rpc=true
rpc-secret=$(openssl rand -hex 16)
quiet=true
log=${HOME}/.config/aria2/aria2.log
log-level=warn
EOF
touch ~/.config/aria2/aria2.session
touch ~/.config/aria2/aria2.log
systemctl --user daemon-reload
systemctl --user enable aria2.service

# System Services
sudo systemctl enable bluetooth systemd-boot-update

# easyeffects preset
mkdir -p ~/.local/share/easyeffects/output
curl -fLo ~/.local/share/easyeffects/output/DTS-Built-In-Speaker.json https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/DTS-Built-In-Speaker.json
curl -fLo ~/.local/share/easyeffects/output/AirPods4-ANC.json https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/AirPods4-ANC.json

# brave command line flags
echo '--disable-features=WaylandWpColorManagerV1' > ~/.config/brave-origin-flags.conf

# fastfetch config
mkdir -p ~/.config/fastfetch
curl -fLo ~/.config/fastfetch/config.jsonc https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/fastfetch-kde.jsonc

# bashrc
mv ~/.bashrc ~/.bashrc.bak
cat > ~/.bashrc <<'EOF'
#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='󰣇 \w ❯ '

HISTCONTROL=ignoreboth

export EDITOR=micro
fastfetch

EOF

# cachy-update config
mkdir -p ~/.local/share/icons/hicolor/scalable/apps
curl -sL https://codeload.github.com/Antiz96/arch-update/tar.gz/main | tar -xz -C ~/.local/share/icons/hicolor/scalable/apps --wildcards --xform 's|.*/arch-|cachy-|' '*/res/icons/arch-*.svg'
cachy-update --check --enable

# Application Launcer icon for KDE (Arch)
curl -fLo ~/.local/share/icons/hicolor/scalable/apps/arch-app-launcher.svg https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/arch-app-launcher.svg

# AIOStreams Desktop
tmp=$(mktemp -d)
curl -fL https://github.com/Viren070/AIOStreams/releases/download/desktop-v0.28.0/aiostreams-desktop-bin.tar.gz | tar -xz -C "$tmp"
(cd "$(dirname "$(find "$tmp" -name PKGBUILD -print -quit)")" && makepkg -si --noconfirm)
rm -rf "$tmp"

# install WARP
sudo pacman -S --needed --noconfirm cloudflare-warp-bin
# start the daemon
sudo systemctl enable --now warp-svc
# wait until the daemon answers instead of a blind sleep
for _ in {1..15}; do
    warp-cli --accept-tos status &>/dev/null && break
    sleep 1
done
# disable the GUI
systemctl --user disable --now warp-taskbar.service
systemctl --user mask warp-taskbar.service
# register and connect
warp-cli --accept-tos registration new
warp-cli --accept-tos connect
warp-cli --accept-tos mode warp+doh
# Fix “Limited Connectivity”
warp-cli --accept-tos tunnel ip add 95.216.195.133

echo "Done!"
read -rp "Reboot? [Y/n]: " REBOOT
if [[ -z $REBOOT || $REBOOT == [yY]* ]]; then
    sudo systemctl reboot
fi

# ssh access
# mkdir -p ~/.ssh
# cp -r /mnt/data/SOFTWARES/arch/.ssh/. ~/.ssh/
# chmod 700 ~/.ssh
# chmod 600 ~/.ssh/id_* ~/.ssh/config
# chmod 644 ~/.ssh/*.pub

# grep rpc-secret ~/.config/aria2/aria2.conf
#    󰆼 #202326
