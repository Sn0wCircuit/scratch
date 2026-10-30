#!/usr/bin/env bash

# Stop script on first error
set -e

TOTAL=$(grep -cE '^\s*step "' "${BASH_SOURCE[0]}")
STEP=0
step() { echo -e "\e[1;32m($((++STEP))/$TOTAL) $1\e[0m"; }

# Ask for the sudo password once and keep it alive for the whole run
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# Ask for the aria2 RPC secret up front (input is hidden)
while true; do
    read -rsp $'\e[1;33mEnter aria2 RPC secret: \e[0m' RPC_SECRET; echo
    read -rsp $'\e[1;33mConfirm aria2 RPC secret: \e[0m' RPC_SECRET2; echo
    if [[ -n "$RPC_SECRET" && "$RPC_SECRET" == "$RPC_SECRET2" ]]; then
        break
    fi
    echo -e "\e[1;31mSecret was empty or did not match, try again.\e[0m"
done
unset RPC_SECRET2

# install WARP
# -Sy refreshes the package db (a fresh install's db can be stale); the full upgrade follows right after
sudo pacman -Sy --needed --noconfirm cloudflare-warp-bin
# start the daemon
sudo systemctl enable --now warp-svc
# wait until the daemon answers instead of a blind sleep
for _ in {1..15}; do
    warp-cli --accept-tos status &>/dev/null && break
    sleep 1
done
# disable the GUI (don't abort if the unit doesn't exist)
systemctl --user disable --now warp-taskbar.service || true
systemctl --user mask warp-taskbar.service || true
# register and connect
warp-cli --accept-tos registration new
warp-cli --accept-tos connect
# Fix “Limited Connectivity”
warp-cli --accept-tos tunnel ip add 95.216.195.133
step "Cloudflare WARP configured"

# Rank Arch + CachyOS mirrors (official tool, same as CachyOS Hello > Rank mirrors)
sudo cachyos-rate-mirrors || echo -e "\e[1;33mMirror ranking failed, continuing with current mirrors\e[0m"
step "Mirrorlist ranked"

# Full system upgrade
sudo pacman --noconfirm -Syu
step "Full system upgrade performed"

sudo tee /etc/systemd/system/mnt-data.mount > /dev/null <<'EOF'
[Unit]
Description=Mount data drive (/mnt/data)

[Mount]
What=UUID=72DC42A1DC425F89
Where=/mnt/data
Type=ntfs
Options=defaults,nofail,uid=1000,gid=1000,rw,user,exec,umask=000

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-data.mount
step "Data drive automount configured"

sudo tee /etc/udev/rules.d/asus-battery-charge-threshold.rules > /dev/null <<'EOF'
ACTION=="add", KERNEL=="asus-nb-wmi", RUN+="/bin/bash -c 'echo 80 > /sys/class/power_supply/BAT1/charge_control_end_threshold'"
EOF
step "Battery charge limit set to 80%"

sudo pacman -S --needed --noconfirm easyeffects lsp-plugins-lv2 brave-origin-bin aria2 xdg-terminal-exec
step "pacman packages installed"

mkdir -p ~/.local/share/easyeffects/output
cp /mnt/data/SOFTWARES/cachy/DTS-Built-In-Speaker.json ~/.local/share/easyeffects/output/
step "EasyEffects preset configured"

mkdir -p ~/.ssh
cp -r /mnt/data/SOFTWARES/cachy/.ssh/. ~/.ssh/
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_* ~/.ssh/config ~/.ssh/authorized_keys 2>/dev/null || true
chmod 644 ~/.ssh/*.pub ~/.ssh/known_hosts 2>/dev/null || true
step "SSH access configured"

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
cat > ~/.config/aria2/aria2.conf <<'EOF'
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
quiet=true
log=${HOME}/.config/aria2/aria2.log
log-level=warn
EOF
# Append the user-supplied secret (printf %s keeps special characters intact)
printf 'rpc-secret=%s\n' "$RPC_SECRET" >> ~/.config/aria2/aria2.conf
chmod 600 ~/.config/aria2/aria2.conf
unset RPC_SECRET
touch ~/.config/aria2/aria2.session
touch ~/.config/aria2/aria2.log
systemctl enable --user aria2.service
step "aria2 configured"

echo "--disable-features=WaylandWpColorManagerV1" > ~/.config/brave-origin-flags.conf
sudo mkdir -p /etc/brave/policies/managed
sudo tee /etc/brave/policies/managed/brave-policies.json > /dev/null <<'EOF'
{
  "PasswordManagerEnabled": false
}
EOF
step "Brave browser configured"

mkdir -p ~/.config/mpv
cat > ~/.config/mpv/mpv.conf <<'EOF'
# Profile
profile=high-quality

# Video output and decoding (NVIDIA)
vo=gpu-next
hwdec=nvdec

# Window
autofit=50%x50%
title=${media-title}
#title-bar=no
#no-border

# Audio and subtitles
alang=eng,en
slang=eng,en
volume=100
volume-max=130
sub-bold=yes

# Network streaming cache
cache=yes
cache-secs=600
demuxer-readahead-secs=600
demuxer-max-bytes=1500MiB
EOF

mkdir -p ~/.local/bin ~/.local/share/applications

cat > ~/.local/bin/mpv-url-handler <<'EOF'
#!/usr/bin/env bash
raw="$1"
enc="${raw#*url=}"
enc="${enc%%&*}"
url="$(printf '%b' "${enc//%/\\x}")"
exec mpv -- "$url"
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

xdg-mime default mpv-url-handler.desktop x-scheme-handler/mpv
step "mpv configured"

mkdir -p ~/.config/fastfetch
cp /mnt/data/SOFTWARES/cachy/logo.txt ~/.config/fastfetch/
cp /mnt/data/SOFTWARES/cachy/config.jsonc ~/.config/fastfetch/
step "fastfetch configured"

# Open Cachy-Update on Alacritty instead of Konsole
echo "Alacritty.desktop" > ~/.config/xdg-terminals.list
if [[ -f ~/.config/alacritty/alacritty.toml ]]; then
    sed -i -E 's/^(\s*)#?\s*opacity\s*=.*/\1opacity = 0.96 # Default 0.8/' ~/.config/alacritty/alacritty.toml
fi
step "Alacritty configured"

kscreen-doctor output.eDP-1.iccprofile./mnt/data/SOFTWARES/cachy/FX506LH_8086_AE0D1521.icm output.eDP-1.colorProfileSource.ICC
step "Display Color Profile Applied"

# NumLock=0 means "on" in kcminputrc (1 = off, 2 = unchanged)
kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0
step "Numlock turned ON"

# Limine edit runs last so no earlier pacman hook can overwrite it
# (/boot is root-only on most installs, hence sudo for grep too)
sudo sed -i 's/^timeout:.*/timeout: 3/' /boot/limine.conf
sudo grep -q '^term_font_scale:' /boot/limine.conf || sudo sed -i '1i term_font_scale: 2x2' /boot/limine.conf
if sudo grep -q '^timeout: 3' /boot/limine.conf && sudo grep -q '^term_font_scale: 2x2' /boot/limine.conf; then
    step "Limine config updated"
else
    echo -e "\e[1;31mLimine config edit did not apply, check /boot/limine.conf\e[0m"
fi

read -rp $'\e[1;32mSuccessfully completed all tasks. Reboot? [Y/n] \e[0m' answer || answer=n
if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
    sudo systemctl reboot
fi
