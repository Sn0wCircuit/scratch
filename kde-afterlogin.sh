#!/usr/bin/env bash

# Fractional Scaling to 125%
kscreen-doctor output.eDP-1.scale.1.25

# Apply ICC Color Profile
mkdir -p ~/.color
curl -fL -o ~/.color/FX506LH_8086_AE0D1521.icm https://raw.githubusercontent.com/Sn0wCircuit/scratch/refs/heads/main/FX506LH_8086_AE0D1521.icm
kscreen-doctor "output.eDP-1.colorProfileSource.ICC" "output.eDP-1.iccprofile.$HOME/.color/FX506LH_8086_AE0D1521.icm"

# Turn on numlock on startup
kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0
