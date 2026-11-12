#!/usr/bin/env bash

# Fractional Scaling to 125%
kscreen-doctor output.eDP-1.scale.1.25

# Apply Built-In EDID Color Profile
kscreen-doctor output.eDP-1.colorProfileSource.EDID

# Turn on numlock on startup
kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0
