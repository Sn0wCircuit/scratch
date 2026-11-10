#!/bin/bash
set -e

timedatectl set-ntp true

# tweak_pacman_conf <pacman.conf>
# Color, ILoveCandy, VerbosePkgLists, DisableDownloadTimeout, ParallelDownloads = 10,
# CheckSpace off and [multilib]. Idempotent.
tweak_pacman_conf() {
    local conf=$1 opt key
    # Not just uncommenting: stock Arch pacman.conf lacks some of these lines (e.g.
    # ILoveCandy), so a plain s/^#X/X/ silently does nothing. For each option, drop any
    # existing line (commented or not, any value) and add one active line under [options].
    # Each add goes right under [options], so the list is in reverse of the final order.
    for opt in "ParallelDownloads = 10" DisableDownloadTimeout VerbosePkgLists ILoveCandy Color; do
        key=${opt%% *}
        sed -i "/^#\?$key\b/d" "$conf"
        sed -i "/^\[options\]/a $opt" "$conf"
    done
    sed -i 's/^CheckSpace/#CheckSpace/' "$conf"
    sed -i 's/^#\[multilib\]/[multilib]/' "$conf"
    sed -i '/^\[multilib\]/{n;s/^#//}' "$conf"
}

# Numbers of all partitions on the disk
list_parts() { sgdisk -p "/dev/$DISK" | awk '$1 ~ /^[0-9]+$/ {print $1}'; }

# Number of the ext4 data partition: the partition whose filesystem label is "Data"
# (what `lsblk -o LABEL` shows) AND whose filesystem type is ext4. Both must be true;
# a partition labeled "Data" with any other fstype does not count.
# Prints nothing if not found.
find_data_part() {
    local n dev
    for n in $(list_parts); do
        dev=$(part "$n")
        [ "$(blkid -s LABEL -o value "$dev" 2>/dev/null)" = Data ] || continue
        [ "$(blkid -s TYPE -o value "$dev" 2>/dev/null)" = ext4 ] || continue
        echo "$n"
        return 0
    done
    return 0
}

# --- Questions ---
lsblk -d -o NAME,SIZE,MODEL
read -rp "Disk name [nvme0n1]: " DISK
DISK=${DISK:-nvme0n1}
case $DISK in *[0-9]) P=p ;; *) P= ;; esac
part() { echo "/dev/$DISK$P$1"; }

read -rp "Default Partition Layout? (Y/n): " DEFAULT_LAYOUT
[[ $DEFAULT_LAYOUT == [nN]* ]] && DEFAULT_LAYOUT=n || DEFAULT_LAYOUT=y

EFI_LABEL=();  BOOT_LABEL=();  ROOT_LABEL=()
DATA_NEW=n
if [ "$DEFAULT_LAYOUT" = y ]; then
    # If an ext4 partition labeled 'Data' exists: every other partition is deleted, then
    # p1-p3 are recreated (root = largest free block). The data partition is never
    # touched: if it isn't p4 it is renumbered to p4 (table entry only, no data moves).
    # If it does not exist, or it exists and you choose to wipe the entire drive anyway
    # (default N): the WHOLE disk is wiped and p1-p4 are created
    # (root 200G, p4 = rest of the disk, ext4, labeled 'Data').
    DATA_NO=$(find_data_part)
    if [ -n "$DATA_NO" ]; then
        read -rp "ext4 'Data' partition found (p$DATA_NO). Wipe the ENTIRE drive anyway? (y/N): " WIPE_ALL
        if [[ $WIPE_ALL == [yY]* ]]; then DATA_NO=; fi
    fi
    [ -n "$DATA_NO" ] || DATA_NEW=y
    EFI=$(part 1);  BOOT=$(part 2);  ROOT=$(part 3);  EXTRA=$(part 4)
    FORMAT_EFI=y
    EXTRA_MNT=/mnt/data
    # filesystem labels (what `lsblk -o LABEL` shows), not GPT partition names
    EFI_LABEL=(-n efi);  BOOT_LABEL=(-L boot);  ROOT_LABEL=(-L /)
else
    read -rp "EFI partition no: " N;  EFI=$(part "$N")
    read -rp "Format EFI? (Y/n): " FORMAT_EFI
    read -rp "Boot (XBOOTLDR) partition no: " N;  BOOT=$(part "$N")
    read -rp "Root partition no: " N;  ROOT=$(part "$N")
    read -rp "Extra Data (ext4) partition no (blank to skip): " N
    if [ -n "$N" ]; then
        EXTRA=$(part "$N")
        read -rp "Extra mountpoint [/mnt/data]: " EXTRA_MNT
        EXTRA_MNT=${EXTRA_MNT:-/mnt/data}
    fi
fi
read -rp "Hostname [archlinux]: " NEWHOST;  NEWHOST=${NEWHOST:-archlinux}
read -rp "Username [shihab]: " NEWUSER;  NEWUSER=${NEWUSER:-shihab}
read -rp "Password (used for root and $NEWUSER): " PASS

# Anything other than n/N means yes
[[ $FORMAT_EFI == [nN]* ]] && FORMAT_EFI=n || FORMAT_EFI=y

# --- Review ---
echo
echo "Disk:     /dev/$DISK"
if [ "$DEFAULT_LAYOUT" = y ]; then
    if [ "$DATA_NEW" = n ]; then
        echo "Layout:   default (wipe ALL partitions except ext4 data partition p$DATA_NO; create EFI 1G 'efi', boot 2G 'boot', root = largest free block '/')"
    else
        echo "Layout:   default (wipe the ENTIRE disk; create EFI 1G 'efi', boot 2G 'boot', root 200G '/', ext4 'Data' = rest of the disk)"
    fi
else
    echo "Layout:   custom (existing partitions)"
fi
echo "EFI:      $EFI (format: $FORMAT_EFI)"
echo "Boot:     $BOOT (format)"
echo "Root:     $ROOT (format)"
echo "Extra:    ${EXTRA:-none}${EXTRA:+ -> $EXTRA_MNT}"
if [ "$DEFAULT_LAYOUT" = y ] && [ "$DATA_NEW" = n ] && [ "$DATA_NO" != 4 ]; then
    echo "          (data partition is currently p$DATA_NO, will be renumbered to p4)"
fi
if [ "$DATA_NEW" = y ]; then
    echo "          (new ext4 partition, will be formatted)"
fi
echo "Hostname: $NEWHOST"
echo "Username: $NEWUSER"
echo "Password: $PASS"
read -rp "Proceed? (Y/n): " OK
[[ $OK == [nN]* ]] && exit 1

# --- Remove existing UEFI boot entries ---
# Keeps entry 0000 only if the EFI partition is NOT being formatted.
for e in $(efibootmgr | grep -oP '^Boot\K[0-9A-F]{4}'); do
    [ "$FORMAT_EFI" = n ] && [ "$e" = 0000 ] && continue
    efibootmgr -b "$e" -B
done

# --- pacman.conf tweaks in the LIVE system (before any package installation) ---
# pacstrap runs pacman with this host config (/etc/pacman.conf unless -C is given).
tweak_pacman_conf /etc/pacman.conf

# --- Hardcoded mirrorlist in the LIVE system (pacstrap uses and copies this) ---
cat > /etc/pacman.d/mirrorlist <<'MIRRORS'
## Bangladesh
Server = https://mirror.xeonbd.com/archlinux/$repo/os/$arch
Server = http://mirror.xeonbd.com/archlinux/$repo/os/$arch
Server = https://mirror.limda.net/archlinux/$repo/os/$arch
Server = http://mirror.limda.net/archlinux/$repo/os/$arch
MIRRORS

# --- Partition, format & mount ---
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
if [ "$DEFAULT_LAYOUT" = y ]; then
    # One sgdisk call = one atomic table write, processed in order:
    # 1) delete every partition except the ext4 data partition, if one exists
    # (signatures wiped first; with no data partition this deletes ALL partitions),
    # 2) if the data partition exists and isn't p4, swap its table entry into slot 4
    # (-r only swaps entries; sectors and data are untouched),
    # 3) create the new partitions in the freed space (start/end 0 = largest free block):
    #    - data partition exists: p1-p3, root takes the largest free block
    #    - no data partition:     p1-p4, root = 200G, p4 (ext4 'Data') = the rest
    SGDISK_ARGS=()
    for n in $(list_parts); do
        [ "$n" = "$DATA_NO" ] && continue
        wipefs -a "$(part "$n")" 2>/dev/null || true
        SGDISK_ARGS+=(-d "$n")
    done
    if [ "$DATA_NEW" = n ]; then
        if [ "$DATA_NO" != 4 ]; then SGDISK_ARGS+=(-r "4:$DATA_NO"); fi
        SGDISK_ARGS+=(-n 1:0:+1G -t 1:ef00 -n 2:0:+2G -t 2:ea00 -n 3:0:0 -t 3:8300)
    else
        SGDISK_ARGS+=(-n 1:0:+1G -t 1:ef00 -n 2:0:+2G -t 2:ea00 -n 3:0:+200G -t 3:8300 -n 4:0:0 -t 4:8300)
    fi
    sgdisk "${SGDISK_ARGS[@]}" "/dev/$DISK"
    partprobe "/dev/$DISK"
    udevadm settle
    wipefs -a "$EFI" "$BOOT" "$ROOT"
    if [ "$DATA_NEW" = y ]; then wipefs -a "$EXTRA"; fi
fi
if [ "$FORMAT_EFI" = y ]; then mkfs.fat -F 32 "${EFI_LABEL[@]}" "$EFI"; fi
mkfs.ext4 -F "${BOOT_LABEL[@]}" "$BOOT"
mkfs.ext4 -F "${ROOT_LABEL[@]}" "$ROOT"
if [ "$DATA_NEW" = y ]; then mkfs.ext4 -F -L Data "$EXTRA"; fi
mount "$ROOT" /mnt
mount -o fmask=0177,dmask=0077 --mkdir "$EFI" /mnt/efi
mount --mkdir "$BOOT" /mnt/boot
if [ "$FORMAT_EFI" = n ]; then
    rm -rf /mnt/efi/loader/ /mnt/efi/EFI/Boot/ /mnt/efi/EFI/systemd/
fi

# --- Base install ---
mkdir -p /mnt/etc && touch /mnt/etc/vconsole.conf
pacstrap -K /mnt base linux linux-firmware

# --- Carry the hardcoded mirrorlist into the NEW system (persists after reboot) ---
cp -f /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# --- pacman.conf tweaks in the NEW system ---
# pacstrap does not use this file. It only exists once pacstrap has installed pacman;
# the tweak applies from the arch-chroot stage onward and to the installed system.
tweak_pacman_conf /mnt/etc/pacman.conf

# --- Fstab (PARTUUID-based) ---
genfstab -t PARTUUID /mnt > /mnt/etc/fstab

# --- Chroot setup ---
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT")
cat > /mnt/setup.sh <<EOF
#!/bin/bash
set -e
sed -i '/^HOOKS=/ s/systemd/systemd plymouth/' /etc/mkinitcpio.conf
pacman -S --needed --noconfirm base-devel intel-ucode networkmanager micro pacman-contrib bash-completion plymouth zram-generator
systemctl enable NetworkManager
echo -e "[zram0]\ncompression-algorithm = zstd\nzram-size = 8192\nswap-priority = 100\nfs-type = swap" > /etc/systemd/zram-generator.conf
ln -sf /usr/share/zoneinfo/Asia/Dhaka /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$NEWHOST" > /etc/hostname
useradd -m -G wheel $NEWUSER
sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
bootctl --esp-path=/efi --boot-path=/boot install
echo -e "title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=PARTUUID=$ROOT_PARTUUID rw zswap.enabled=0 nowatchdog quiet splash" > /boot/loader/entries/arch.conf
sed -i 's/^#timeout 3/timeout 3/' /efi/loader/loader.conf
sed -i '1i default arch.conf' /efi/loader/loader.conf
EOF

# --- Extra partition: systemd mount unit (instead of an fstab entry), created inside the chroot ---
if [ -n "$EXTRA" ]; then
    EXTRA_PARTUUID=$(blkid -s PARTUUID -o value "$EXTRA")
    cat >> /mnt/setup.sh <<EOF
EXTRA_UNIT=\$(systemd-escape -p --suffix=mount "$EXTRA_MNT")
mkdir -p "$EXTRA_MNT"
cat > "/etc/systemd/system/\$EXTRA_UNIT" <<UNIT
[Unit]
Description=Mount data drive ($EXTRA_MNT)

[Mount]
What=/dev/disk/by-partuuid/$EXTRA_PARTUUID
Where=$EXTRA_MNT
Type=ext4
Options=defaults,exec,rw,noatime

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable "\$EXTRA_UNIT"
EOF
fi

arch-chroot -S /mnt /bin/bash /setup.sh
rm /mnt/setup.sh

# Passwords set outside the script file so special characters are safe
echo "root:$PASS" | arch-chroot /mnt chpasswd
echo "$NEWUSER:$PASS" | arch-chroot /mnt chpasswd

# Freshly created Data partition only: mkfs leaves its root directory owned by root, so
# hand it to the new user (stored on the filesystem, persists). An existing Data
# partition keeps its ownership untouched.
if [ "$DATA_NEW" = y ]; then
    mount "$EXTRA" "/mnt$EXTRA_MNT"
    arch-chroot /mnt chown "$NEWUSER:" "$EXTRA_MNT"
    umount "/mnt$EXTRA_MNT"
fi

# --- Finalize: ext4 EFI driver & Consolefont---
mkdir -p /mnt/efi/EFI/systemd/drivers
cp /usr/share/refind/drivers_x64/ext4_x64.efi /mnt/efi/EFI/systemd/drivers/
cp /usr/share/kbd/consolefonts/ter-122b.psf.gz /mnt/usr/share/kbd/consolefonts/
echo "FONT=ter-122b" > /mnt/etc/vconsole.conf
umount -R /mnt
echo "Done! Reboot now."
