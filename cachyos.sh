#!/usr/bin/env bash

# Stop script on first error
set -e

# Full system upgrade
sudo pacman --noconfirm -Syu
echo -e "\e[1;32m(1/13) Full system upgrade performed\e[0m"

sudo sed -i -e 's/^timeout:.*/timeout: 3/' -e '1i term_font_scale: 2x2' /boot/limine.conf
echo -e "\e[1;32m(2/13) Limine config updated\e[0m"

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
echo -e "\e[1;32m(3/13) Data drive automount configured\e[0m"

sudo tee /etc/udev/rules.d/asus-battery-charge-threshold.rules > /dev/null <<'EOF'
ACTION=="add", KERNEL=="asus-nb-wmi", RUN+="/bin/bash -c 'echo 80 > /sys/class/power_supply/BAT1/charge_control_end_threshold'"
EOF
echo -e "\e[1;32m(4/13) Battery charge limit set to 80%\e[0m"

sudo pacman -S --needed --noconfirm easyeffects lsp-plugins-lv2 brave-origin-bin cloudflare-warp-bin aria2 xdg-terminal-exec
echo -e "\e[1;32m(5/13) pacman packages installed\e[0m"

# start the daemon
sudo systemctl enable --now warp-svc
sleep 3
# disable the GUI
systemctl --user disable --now warp-taskbar.service
systemctl --user mask warp-taskbar.service
# register and connect
warp-cli --accept-tos registration new
warp-cli --accept-tos connect
# Fix “Limited Connectivity”
warp-cli --accept-tos tunnel ip add 95.216.195.133
echo -e "\e[1;32m(6/13) Cloudflare WARP configured\e[0m"

mkdir -p ~/.local/share/easyeffects/output
cp /mnt/data/SOFTWARES/cachy/DTS.json ~/.local/share/easyeffects/output/
echo -e "\e[1;32m(7/13) EasyEffects preset configured\e[0m"

cp -r /mnt/data/SOFTWARES/cachy/.ssh ~/.ssh
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_* ~/.ssh/config ~/.ssh/authorized_keys 2>/dev/null || true
chmod 644 ~/.ssh/*.pub ~/.ssh/known_hosts 2>/dev/null || true
echo -e "\e[1;32m(8/13) SSH access configured\e[0m"

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
rpc-secret=1610017
quiet=true
log=${HOME}/.config/aria2/aria2.log
log-level=warn
EOF
touch ~/.config/aria2/aria2.session
touch ~/.config/aria2/aria2.log
systemctl enable --user aria2.service
echo -e "\e[1;32m(9/13) aria2 configured\e[0m"

echo "--disable-features=WaylandWpColorManagerV1" > ~/.config/brave-origin-flags.conf
sudo mkdir -p /etc/brave/policies/managed
sudo tee /etc/brave/policies/managed/brave-policies.json > /dev/null <<'EOF'
{
  "PasswordManagerEnabled": false
}
EOF
echo -e "\e[1;32m(10/13) Brave browser configured\e[0m"

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
echo -e "\e[1;32m(11/13) mpv configured\e[0m"

mkdir -p ~/.config/fastfetch
cp /mnt/data/SOFTWARES/cachy/logo.txt ~/.config/fastfetch/
cp /mnt/data/SOFTWARES/cachy/config.jsonc ~/.config/fastfetch/
echo -e "\e[1;32m(12/13) fastfetch configured\e[0m"

# Open Cachy-Update on Alacrity instead of Konsole
echo "Alacritty.desktop" > ~/.config/xdg-terminals.list
sed -i -E 's/^(\s*)#?\s*opacity\s*=.*/\1opacity = 0.96 # Default 0.8/' ~/.config/alacritty/alacritty.toml
echo -e "\e[1;32m(13/13) Alacritty configured\e[0m"

read -rp $'\e[1;32mSuccessfully completed all tasks. Reboot? [Y/n] \e[0m' answer || answer=n
if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
    sudo systemctl reboot
fi
