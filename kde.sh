#!/usr/bin/env bash

# Fractional Scaling to 125%
kscreen-doctor output.eDP-1.scale.1.25

# Apply ICC Color Profile
kscreen-doctor "output.eDP-1.colorProfileSource.ICC" "output.eDP-1.iccprofile./mnt/data/SOFTWARES/arch/FX506LH_8086_AE0D1521.icm"

# Turn on numlock on startup
kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0
