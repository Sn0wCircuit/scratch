#!/bin/bash

set -e

# nmcli device wifi connect "" password ""
n=$(nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2=="802-11-wireless"{print $1; exit}'); nmcli connection modify "$n" 802-11-wireless-security.key-mgmt sae; [ "$(nmcli -g 802-11-wireless-security.key-mgmt connection show "$n")" = sae ] && printf '\e[32m✔ "%s" is set to SAE (WPA3-Personal)\e[0m\n' "$n" || printf '\e[31m✘ "%s" is NOT set to SAE\e[0m\n' "$n"

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
sudo curl -fLo /usr/lib/udev/rules.d/80-nvidia-pm.rules https://gitlab.com/asus-linux/nvidia-laptop-power-cfg/-/raw/main/nvidia.rules?inline=false
sudo systemctl enable nvidia-powerd.service

# Fonts & Audio
sudo pacman -S --needed --noconfirm pipewire pipewire-pulse pipewire-jack pipewire-alsa wireplumber noto-fonts noto-fonts-emoji noto-fonts-extra noto-fonts-cjk ttf-jetbrains-mono-nerd

# Install & Configure Noctalia+Umbriel
sudo pacman -S --needed --noconfirm umbriel noctalia noctalia-greeter kitty yazi 7zip fd swayimg bluez bluez-utils wl-clipboard upower xdg-terminal-exec
mkdir -p ~/.config/umbriel
cp /usr/share/umbriel/config.toml ~/.config/umbriel/config.toml
sed -i \
  -e 's|^# autostart = .*|autostart = ["noctalia"]\nshow_cheatsheet = false|' \
  -e 's|^# \[output\.DP-1\]|[output.eDP-1]|' \
  -e 's|^# scale = .*|scale = 1.25|' \
  -e 's|^# color_profile = .*|color_profile = "edid"|' \
  -e 's|^# sdr_gamut = .*|sdr_gamut = "srgb"|' \
  -e '/^\[layout\]$/a gap = 4' \
  -e '/noctalia msg screenshot-\(region\|window\|fullscreen\)/d' \
  -e '/^\[keybinds\]/a # Screenshot\n"Print" = "spawn noctalia msg screenshot-region"\n"Mod+Print" = "spawn noctalia msg screenshot-window"\n"Ctrl+Print" = "spawn noctalia msg screenshot-fullscreen"' \
  -e '/^\[keybinds\]/a # Brave and Yazi\n"Mod+B" = "spawn brave-origin"\n"Mod+Y" = "spawn kitty yazi"' \
  ~/.config/umbriel/config.toml
printf '\n[[window_rule]]\nmatch.is_alone = true\ndefault_maximize = true\n' >> ~/.config/umbriel/config.toml
if grep -q '^\[environment\]' ~/.config/umbriel/config.toml; then
  sed -i \
    -e '/^\[environment\]/,/^\[/{/^[[:space:]]*\(EDITOR\|VISUAL\)[[:space:]]*=/d}' \
    -e '/^\[environment\]/a EDITOR = "micro"\nVISUAL = "micro"' \
    ~/.config/umbriel/config.toml
else
  printf '\n[environment]\nEDITOR = "micro"\nVISUAL = "micro"\n' >> ~/.config/umbriel/config.toml
fi

mkdir -p ~/.config/noctalia
mkdir -p ~/Pictures/Wallpapers ~/Documents
curl -fLo ~/Pictures/Wallpapers/lab.jpg https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/lab.jpg
curl -fLo ~/.config/noctalia/config.toml https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/noctalia-config.toml

# noctalia-greeter config
sudo sed -i '/^\[default_session\]/,/^\[/ s|^command[[:space:]]*=.*|command = "/usr/bin/noctalia-greeter-session"|' /etc/greetd/config.toml
sudo systemd-tmpfiles --create noctalia-greeter.conf
sudo env GREETER_USER=greeter noctalia-greeter-apply-appearance --setup-system
# Catppuccin-Mocha-Blue theme
sudo tee /var/lib/noctalia-greeter/greeter.toml >/dev/null <<'EOF'
[appearance]
scheme = "Synced"
hide_logo = true
theme_mode = "dark"

[appearance.palette]
primary = "#89b4fa"
on_primary = "#11111b"
secondary = "#fab387"
on_secondary = "#11111b"
tertiary = "#94e2d5"
on_tertiary = "#11111b"
error = "#f38ba8"
on_error = "#11111b"
surface = "#1e1e2e"
on_surface = "#cdd6f4"
surface_variant = "#313244"
on_surface_variant = "#a3b4eb"
outline = "#4c4f69"
shadow = "#11111b"
hover = "#94e2d5"
on_hover = "#11111b"
EOF
sudo chown greeter:greeter /var/lib/noctalia-greeter/greeter.toml
sudo chmod 644 /var/lib/noctalia-greeter/greeter.toml
sudo systemctl enable greetd upower

# Enable User Audio Services
systemctl --user enable pipewire pipewire-pulse wireplumber

# Applications & Tools
sudo pacman -S --needed --noconfirm cachy-update brave-origin-bin easyeffects lsp-plugins-lv2 asusctl rog-control-center mpv aria2 fastfetch openssh sbctl

# mpv Configuration
mkdir -p ~/.config/mpv
cat > ~/.config/mpv/mpv.conf <<'EOF'
# Profile
profile=high-quality

# Video output and decoding (NVIDIA)
vo=gpu-next
hwdec=nvdec

# Audio and subtitles
alang=eng,en
slang=eng,en
volume=80
volume-max=130
sub-bold=yes

# Network streaming cache
cache=yes
cache-secs=600
demuxer-readahead-secs=600
demuxer-max-bytes=1500MiB

EOF

# configure mpv://?url={encodedUrl}&sub={subtitles}
mkdir -p ~/.local/bin ~/.local/share/applications
cat > ~/.local/bin/mpv-url-handler <<'EOF'
#!/usr/bin/env bash
dec() { local s="${1//\\/\\\\}"; printf '%b' "${s//%/\\x}"; }

url=""
subs=()
IFS='&' read -ra parts <<< "${1#*\?}"

for p in "${parts[@]}"; do
  case "$p" in
    url=*) url="$(dec "${p#url=}")" ;;
    sub=*) subs+=("--sub-file=$(dec "${p#sub=}")") ;;
  esac
done

exec mpv "${subs[@]}" -- "$url"
EOF
chmod +x ~/.local/bin/mpv-url-handler
cat > ~/.local/share/applications/mpv-url-handler.desktop <<EOF
[Desktop Entry]
Type=Application
Name=mpv URL Handler
Exec=$HOME/.local/bin/mpv-url-handler %u
NoDisplay=true
MimeType=x-scheme-handler/mpv;
EOF
update-desktop-database ~/.local/share/applications
xdg-mime default mpv-url-handler.desktop x-scheme-handler/mpv

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
mkdir -p ~/Downloads
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
systemctl --user enable --now aria2.service

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
curl -fLo ~/.config/fastfetch/logo.txt https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/logo.txt
curl -fLo ~/.config/fastfetch/config.jsonc https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/config.jsonc

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
[ "$TERM" = "xterm-kitty" ] && alias ssh='kitten ssh'
PS1='󰣇 \w ❯ '

HISTCONTROL=ignoreboth

function y() {
	local tmp cwd; tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
	command yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd" || builtin true
	command rm -f -- "$tmp"
}

export EDITOR=micro
fastfetch

EOF

# kitty config
mkdir -p ~/.config/kitty/themes
curl -fLo ~/.config/kitty/themes/catppuccin-mocha.conf https://raw.githubusercontent.com/catppuccin/kitty/refs/heads/main/themes/mocha.conf
cat > ~/.config/kitty/kitty.conf <<'EOF'
include themes/catppuccin-mocha.conf
font_family JetBrainsMono Nerd Font

EOF

# micro config
mkdir -p ~/.config/micro/colorschemes
curl -fLo ~/.config/micro/colorschemes/catppuccin-mocha.micro https://raw.githubusercontent.com/catppuccin/micro/refs/heads/main/themes/catppuccin-mocha.micro
# on micro, Ctrl+E > set colorscheme catppuccin-mocha
# 'sudo micro <file>' doesn't follow the colorscheme by default, use 'sudoedit <file>' instead

# yazi config
mkdir -p ~/.config/yazi/flavors/catppuccin-mocha.yazi
curl -fLo ~/.config/yazi/flavors/catppuccin-mocha.yazi/flavor.toml https://raw.githubusercontent.com/yazi-rs/flavors/refs/heads/main/catppuccin-mocha.yazi/flavor.toml
curl -fLo ~/.config/yazi/flavors/catppuccin-mocha.yazi/tmtheme.xml https://raw.githubusercontent.com/yazi-rs/flavors/refs/heads/main/catppuccin-mocha.yazi/tmtheme.xml
cat > ~/.config/yazi/theme.toml <<'EOF'
[flavor]
dark = "catppuccin-mocha"
EOF
cat > ~/.config/yazi/yazi.toml <<'EOF'
[mgr]
show_hidden = true
ratio = [2, 3, 3]

[opener]
play = [
	{ run = "mpv %s", orphan = true, for = "unix" },
]
image = [
	{ run = "swayimg %s", orphan = true, desc = "swayimg", for = "unix" },
]

[open]
prepend_rules = [
	{ mime = "image/*", use = "image" },
]

EOF
cat > ~/.config/yazi/keymap.toml <<'EOF'
[mgr]
prepend_keymap = [
  { on = ["g", "m"], run = "cd /mnt/data", desc = "Data" },
]
EOF

# swayimg config
mkdir -p ~/.config/swayimg
cat > ~/.config/swayimg/init.lua <<'EOF'
swayimg.text.visible = false
swayimg.viewer.on_key("i", function()
  swayimg.text.visible = not swayimg.text.visible
end)
swayimg.gallery.on_key("i", function()
  swayimg.text.visible = not swayimg.text.visible
end)
swayimg.imagelist.adjacent = true
swayimg.viewer.on_key("Left", function() swayimg.viewer.open("prev") end)
swayimg.viewer.on_key("Right", function() swayimg.viewer.open("next") end)
EOF

# gtk3 dark mode fix
mkdir -p ~/.config/gtk-3.0
cat > ~/.config/gtk-3.0/settings.ini <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
EOF

# cachy-update config
mkdir -p ~/.local/share/icons/hicolor/scalable/apps ~/.config/arch-update
curl -sL https://codeload.github.com/Antiz96/arch-update/tar.gz/main | tar -xz -C ~/.local/share/icons/hicolor/scalable/apps --wildcards --xform 's|.*/arch-|cachy-|' '*/res/icons/arch-*.svg'
echo 'TrayIconStyle=light' > ~/.config/arch-update/arch-update.conf
cachy-update --check --enable

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

echo "Done!"
read -rp "Reboot? [Y/n]: " REBOOT
if [[ -z $REBOOT || $REBOOT == [yY]* ]]; then
    sudo systemctl reboot
fi
