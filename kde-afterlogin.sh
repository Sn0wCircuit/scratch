#!/usr/bin/env bash

set -euo pipefail

# Fractional Scaling to 125%
kscreen-doctor output.eDP-1.scale.1.25

# Apply ICC Color Profile
mkdir -p ~/.local/share/color/icc
curl -fLo ~/.local/share/color/icc/FX506LH_8086_AE0D1521.icm https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/FX506LH_8086_AE0D1521.icm
kscreen-doctor "output.eDP-1.colorProfileSource.ICC" "output.eDP-1.iccprofile.$HOME/.local/share/color/icc/FX506LH_8086_AE0D1521.icm"

# Turn on numlock on startup
kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0

# Set Display Dim to Never
for profile in AC Battery LowBattery; do
  kwriteconfig6 --file powerdevilrc --group "$profile" --group Display --key DimDisplayWhenIdle false
done
systemctl --user restart plasma-powerdevil.service

echo "Done!"
read -rp "Reboot? [Y/n]: " REBOOT
if [[ -z $REBOOT || $REBOOT == [yY]* ]]; then
    sudo systemctl reboot
fi
