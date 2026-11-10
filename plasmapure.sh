#!/bin/bash

# Stop script on first error
set -e

# nmcli device wifi connect "" password ""

sudo pacman -Syu --noconfirm

# Install Nvidia Driver
sudo pacman -S --needed --noconfirm linux-cachyos-nvidia-open

# Intel Drivers
sudo pacman -S --needed --noconfirm intel-media-driver vulkan-intel

# Nvidia System Configs
sudo tee /etc/modprobe.d/nvidia.conf >/dev/null <<'EOF'
options nvidia_drm modeset=1
options nvidia NVreg_EnableGpuFirmware=0 NVreg_DynamicPowerManagement=0x02
EOF
sudo curl -fL -o /usr/lib/udev/rules.d/80-nvidia-pm.rules https://gitlab.com/asus-linux/nvidia-laptop-power-cfg/-/raw/main/nvidia.rules?inline=false
sudo systemctl enable nvidia-powerd.service

# Fonts & Audio
sudo pacman -S --needed --noconfirm pipewire pipewire-pulse pipewire-jack pipewire-alsa wireplumber noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd

# Install KDE Plasma
sudo pacman -S --needed --noconfirm plasma-meta ark dolphin gwenview konsole kate kcolorchooser tesseract-data-eng wl-clipboard

# Enable User Audio Services
systemctl --user enable pipewire pipewire-pulse wireplumber

# Applications & Tools
sudo pacman -S --needed --noconfirm brave-origin-bin easyeffects lsp-plugins-lv2 asusctl rog-control-center mpv aria2 fastfetch openssh

# mpv Configuration
mkdir -p ~/.config/mpv
cat > ~/.config/mpv/mpv.conf <<'EOF'
# Window
autofit=50%x50%

# Audio and subtitles
alang=eng,en
slang=eng,en
volume=100
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
rpc-secret=dina
quiet=true
log=${HOME}/.config/aria2/aria2.log
log-level=warn
EOF
touch ~/.config/aria2/aria2.session
touch ~/.config/aria2/aria2.log
systemctl --user daemon-reload
systemctl --user enable --now aria2.service

# System Services
sudo systemctl enable bluetooth systemd-boot-update plasmalogin

# easyeffects preset
mkdir -p ~/.local/share/easyeffects/output
curl -fL -o ~/.local/share/easyeffects/output/DTS-Built-In-Speaker.json https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/DTS-Built-In-Speaker.json
curl -fL -o ~/.local/share/easyeffects/output/AirPods4-ANC.json https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/AirPods4-ANC.json

# brave command line flags
echo "--disable-features=WaylandWpColorManagerV1" > ~/.config/brave-origin-flags.conf

# fastfetch config
mkdir -p ~/.config/fastfetch
curl -fL -o ~/.config/fastfetch/logo.txt https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/logo.txt
curl -fL -o ~/.config/fastfetch/config.jsonc https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/config.jsonc

# bashrc
mv ~/.bashrc ~/.bashrc.bak
curl -fL -o ~/.bashrc https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/.bashrc

# ssh access
# mkdir -p ~/.ssh
# cp -r /mnt/data/SOFTWARES/arch/.ssh/. ~/.ssh/
# chmod 700 ~/.ssh
# chmod 600 ~/.ssh/id_* ~/.ssh/config
# chmod 644 ~/.ssh/*.pub

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

sudo cachyos-rate-mirrors || echo -e "\e[1;33mMirror ranking failed\e[0m"
sudo pacman -Syu --noconfirm
sudo pacman -S --needed --noconfirm noto-fonts-extra noto-fonts-cjk

echo -e "\e[1;32m=== Setup complete ===\e[0m"

# AFTER LOGIN
#1d99f3
# aiostreams app
# curl -fLo ~/Downloads/aiostreams-desktop-linux-x64.flatpak https://github.com/Viren070/AIOStreams/releases/download/desktop/aiostreams-desktop-linux-x64.flatpak
# flatpak install --user ~/Downloads/aiostreams-desktop-linux-x64.flatpak -y