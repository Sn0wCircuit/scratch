#!/bin/bash
set -e

timedatectl set-ntp true

# --- CachyOS repo settings (taken from CachyOS's official cachyos-repo.sh) ---
# If a download 404s one day, bump these to the versions listed on
# https://wiki.cachyos.org/features/optimized_repos/
CACHY_KEY=F3B607488DB35A47
CACHY_URL=https://mirror.cachyos.org/repo/x86_64/cachyos
CACHY_PKGS_U=(
    "$CACHY_URL/cachyos-keyring-20240331-1-any.pkg.tar.zst"
    "$CACHY_URL/cachyos-mirrorlist-27-1-any.pkg.tar.zst"
    "$CACHY_URL/cachyos-v3-mirrorlist-27-1-any.pkg.tar.zst"
    "$CACHY_URL/cachyos-v4-mirrorlist-27-1-any.pkg.tar.zst"
    "$CACHY_URL/pacman-7.1.0.r9.g54d9411-5-x86_64.pkg.tar.zst"
)

# Highest x86-64 level this CPU supports (same check CachyOS's script uses)
detect_level() {
    local out
    out=$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null || true)
    if grep -q 'x86-64-v4 (supported, searched)' <<<"$out"; then echo v4
    elif grep -q 'x86-64-v3 (supported, searched)' <<<"$out"; then echo v3
    else echo none
    fi
}

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

# add_cachyos_repos <pacman.conf> <v3|v4>
# Removes any existing [cachyos*] sections, then inserts the CachyOS repos
# ABOVE [core] (required: first repo containing a package wins). Idempotent.
add_cachyos_repos() {
    local conf=$1 level=$2 blockfile
    blockfile=$(mktemp)
    {
        printf '[cachyos-%s]\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$level"
        printf '[cachyos-core-%s]\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$level"
        printf '[cachyos-extra-%s]\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$level"
        printf '[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n'
    } > "$blockfile"
    awk -v bf="$blockfile" '
        /^\[/ { skip = ($0 ~ /^\[cachyos/) }
        skip { next }
        /^\[[^] ]+\]/ && $0 != "[options]" && !done {
            while ((getline line < bf) > 0) print line
            close(bf); print ""; done = 1
        }
        { print }
        END { if (!done) { print ""; while ((getline line < bf) > 0) print line } }
    ' "$conf" > "$conf.new"
    mv "$conf.new" "$conf"
    rm -f "$blockfile"
    # CachyOS's pacman fork picks x86_64 / x86_64_v3 / x86_64_v4 automatically
    sed -i 's/^Architecture[[:space:]]*=.*/Architecture = auto/' "$conf"
    grep -q "^\[cachyos-core-$level\]" "$conf" || { echo "Failed to add CachyOS repos to $conf" >&2; exit 1; }
}

# Trust the CachyOS signing key in the live system's keyring
import_cachy_key() {
    local ok=0 ks
    # wait (max 60s) for the live ISO's keyring init
    for _ in $(seq 60); do [ -s /etc/pacman.d/gnupg/trustdb.gpg ] && break; sleep 1; done
    for ks in hkps://keyserver.ubuntu.com keyserver.ubuntu.com; do
        if pacman-key --recv-keys "$CACHY_KEY" --keyserver "$ks"; then ok=1; break; fi
    done
    if [ $ok -eq 0 ]; then
        echo "Keyserver failed, trying plain HTTPS download of the key..."
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$CACHY_KEY" -o /tmp/cachyos.asc
        pacman-key --add /tmp/cachyos.asc
    fi
    pacman-key --lsign-key "$CACHY_KEY"
}

# Rank the Arch + CachyOS mirrors with CachyOS's own tool (needs the [cachyos] repo).
# It rewrites /etc/pacman.d/mirrorlist and the cachyos mirrorlists.
rank_mirrors() {
    pacman -S --noconfirm --needed cachyos-rate-mirrors
    cachyos-rate-mirrors
    pacman -Sy
}

# Numbers of all partitions on the disk
list_parts() { sgdisk -p "/dev/$DISK" | awk '$1 ~ /^[0-9]+$/ {print $1}'; }

# Number of the NTFS data partition: the partition whose filesystem label is "Data"
# (what `lsblk -o LABEL` shows), verified to be NTFS. Prints nothing if not found.
find_data_part() {
    local n dev
    for n in $(list_parts); do
        dev=$(part "$n")
        [ "$(blkid -s LABEL -o value "$dev" 2>/dev/null)" = Data ] || continue
        [ "$(blkid -s TYPE -o value "$dev" 2>/dev/null)" = ntfs ] || continue
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
if [ "$DEFAULT_LAYOUT" = y ]; then
    # Every partition except the NTFS partition labeled 'Data' gets deleted, then p1-p3
    # are recreated. The NTFS data partition is never touched: if it isn't p4 it is
    # renumbered to p4 (table entry only, no data moves).
    DATA_NO=$(find_data_part)
    [ -n "$DATA_NO" ] || { echo "No NTFS partition labeled 'Data' found on /dev/$DISK"; exit 1; }
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
    read -rp "Extra NTFS partition no (blank to skip): " N
    if [ -n "$N" ]; then
        EXTRA=$(part "$N")
        read -rp "Extra mountpoint [/mnt/data]: " EXTRA_MNT
        EXTRA_MNT=${EXTRA_MNT:-/mnt/data}
    fi
fi
read -rp "Hostname [archlinux]: " NEWHOST;  NEWHOST=${NEWHOST:-archlinux}
read -rp "Username [shihab]: " NEWUSER;  NEWUSER=${NEWUSER:-shihab}
read -rp "Root password: " ROOT_PASS
read -rp "User password: " USER_PASS

DETECTED_LEVEL=$(detect_level)
echo
echo "Detected CPU level: $DETECTED_LEVEL"
if [ "$DETECTED_LEVEL" = v4 ]; then
    echo "NOTE: Intel 12th gen (Alder Lake) and newer can report v4 but cannot run AVX-512."
    echo "      If your CPU is one of those, choose v3."
fi
read -rp "CachyOS optimized repos: v4 / v3 / none [$DETECTED_LEVEL]: " CPU_LEVEL
CPU_LEVEL=${CPU_LEVEL:-$DETECTED_LEVEL}
case $CPU_LEVEL in v3|v4|none) ;; *) echo "Invalid level: $CPU_LEVEL"; exit 1 ;; esac

# Anything other than n/N means yes
[[ $FORMAT_EFI == [nN]* ]] && FORMAT_EFI=n || FORMAT_EFI=y

# --- Review ---
echo
echo "Disk:     /dev/$DISK"
if [ "$DEFAULT_LAYOUT" = y ]; then
    echo "Layout:   default (wipe ALL partitions except NTFS data partition p$DATA_NO; create EFI 1G 'efi', boot 2G 'boot', root = rest '/')"
else
    echo "Layout:   custom (existing partitions)"
fi
echo "EFI:      $EFI (format: $FORMAT_EFI)"
echo "Boot:     $BOOT (format)"
echo "Root:     $ROOT (format)"
echo "Extra:    ${EXTRA:-none}${EXTRA:+ -> $EXTRA_MNT}"
if [ "$DEFAULT_LAYOUT" = y ] && [ "$DATA_NO" != 4 ]; then
    echo "          (data partition is currently p$DATA_NO, will be renumbered to p4)"
fi
echo "Hostname: $NEWHOST"
echo "Username: $NEWUSER"
echo "Root pw:  $ROOT_PASS"
echo "User pw:  $USER_PASS"
echo "CachyOS:  $CPU_LEVEL"
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

# --- CachyOS repos + ranked mirrors in the LIVE system ---
# Done before formatting so a network/key problem aborts before touching disks.
if [ "$CPU_LEVEL" != none ]; then
    import_cachy_key
    # Installs keyring, mirrorlists and CachyOS's pacman fork (needed for the
    # $arch_v3/$arch_v4 mirror variables and the automatic architecture check)
    pacman -U --noconfirm --needed "${CACHY_PKGS_U[@]}"
    add_cachyos_repos /etc/pacman.conf "$CPU_LEVEL"
    pacman -Sy
    rank_mirrors
    echo "Live pacman: $(pacman -Q pacman)"
    pacman -Si linux | grep -E '^(Repository|Version|Architecture)' || true
fi

# --- Partition, format & mount ---
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
if [ "$DEFAULT_LAYOUT" = y ]; then
    # One sgdisk call = one atomic table write, processed in order:
    # 1) delete every partition except the NTFS data partition (signatures wiped first),
    # 2) if the data partition isn't p4, swap its table entry into slot 4 (-r only swaps
    # entries; sectors and data are untouched), 3) create p1-p3 in the freed space
    # (start/end 0 = largest free block).
    SGDISK_ARGS=()
    for n in $(list_parts); do
        [ "$n" = "$DATA_NO" ] && continue
        wipefs -a "$(part "$n")" 2>/dev/null || true
        SGDISK_ARGS+=(-d "$n")
    done
    if [ "$DATA_NO" != 4 ]; then SGDISK_ARGS+=(-r "4:$DATA_NO"); fi
    SGDISK_ARGS+=(-n 1:0:+1G -t 1:ef00 -n 2:0:+2G -t 2:ea00 -n 3:0:0 -t 3:8300)
    sgdisk "${SGDISK_ARGS[@]}" "/dev/$DISK"
    partprobe "/dev/$DISK"
    udevadm settle
    wipefs -a "$EFI" "$BOOT" "$ROOT"
fi
if [ "$FORMAT_EFI" = y ]; then mkfs.fat -F 32 "${EFI_LABEL[@]}" "$EFI"; fi
mkfs.ext4 -F "${BOOT_LABEL[@]}" "$BOOT"
mkfs.ext4 -F "${ROOT_LABEL[@]}" "$ROOT"
mount "$ROOT" /mnt
mount -o fmask=0177,dmask=0077 --mkdir "$EFI" /mnt/efi
mount --mkdir "$BOOT" /mnt/boot
if [ "$FORMAT_EFI" = n ]; then
    rm -rf /mnt/efi/loader/ /mnt/efi/EFI/Boot/ /mnt/efi/EFI/systemd/
fi

# --- Base install ---
mkdir -p /mnt/etc && touch /mnt/etc/vconsole.conf
PACSTRAP_PKGS=(base linux-cachyos linux-firmware)
if [ "$CPU_LEVEL" != none ]; then
    # cachyos/pacman: make sure the fork (not a generic rebuild) lands in the new system;
    # the keyring + mirrorlists are required by the repos we add to its pacman.conf below
    PACSTRAP_PKGS+=(cachyos/pacman cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist)
fi
pacstrap -K /mnt "${PACSTRAP_PKGS[@]}"

# --- pacman.conf tweaks in the NEW system ---
# pacstrap does not use this file. It only exists once pacstrap has installed pacman;
# the tweak applies from the arch-chroot stage onward and to the installed system.
tweak_pacman_conf /mnt/etc/pacman.conf

# --- CachyOS repos + keyring in the NEW system (persists after reboot) ---
if [ "$CPU_LEVEL" != none ]; then
    [ -f /mnt/etc/pacman.conf ] || cp /etc/pacman.conf /mnt/etc/pacman.conf
    # keep the ranked CachyOS mirrorlists from the live system
    # (pacstrap already copied the ranked Arch /etc/pacman.d/mirrorlist)
    cp -f /etc/pacman.d/cachyos-mirrorlist /etc/pacman.d/cachyos-v3-mirrorlist /etc/pacman.d/cachyos-v4-mirrorlist /mnt/etc/pacman.d/
    add_cachyos_repos /mnt/etc/pacman.conf "$CPU_LEVEL"
    # trust every installed keyring (archlinux + cachyos) in the new system
    arch-chroot /mnt /bin/bash -c '
        set -e
        [ -f /etc/pacman.d/gnupg/trustdb.gpg ] || pacman-key --init
        cd /usr/share/pacman/keyrings
        names=()
        for f in *.gpg; do names+=("${f%.gpg}"); done
        pacman-key --populate "${names[@]}"
    '
fi

# --- Fstab (PARTUUID-based) ---
genfstab -t PARTUUID /mnt > /mnt/etc/fstab

# --- Chroot setup ---
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT")
cat > /mnt/setup.sh <<EOF
#!/bin/bash
set -e
sed -i '/^HOOKS=/ s/systemd/systemd plymouth/' /etc/mkinitcpio.conf
pacman -S --needed --noconfirm base-devel intel-ucode networkmanager cachyos-rate-mirrors micro pacman-contrib bash-completion plymouth zram-generator
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
echo -e "title Arch Linux\nlinux /vmlinuz-linux-cachyos\ninitrd /initramfs-linux-cachyos.img\noptions root=PARTUUID=$ROOT_PARTUUID rw zswap.enabled=0 nowatchdog quiet splash" > /boot/loader/entries/arch.conf
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
Type=ntfs
Options=defaults,uid=1000,gid=1000,rw,exec,umask=000

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable "\$EXTRA_UNIT"
EOF
fi

arch-chroot -S /mnt /bin/bash /setup.sh
rm /mnt/setup.sh

# Passwords set outside the script file so special characters are safe
echo "root:$ROOT_PASS" | arch-chroot /mnt chpasswd
echo "$NEWUSER:$USER_PASS" | arch-chroot /mnt chpasswd

# --- Finalize: ext4 EFI driver & Consolefont---
mkdir -p /mnt/efi/EFI/systemd/drivers
cp /usr/share/refind/drivers_x64/ext4_x64.efi /mnt/efi/EFI/systemd/drivers/
cp /usr/share/kbd/consolefonts/ter-122b.psf.gz /mnt/usr/share/kbd/consolefonts/ter-122b.psf.gz
echo "FONT=ter-122b" > /mnt/etc/vconsole.conf
umount -R /mnt
echo "Done! Reboot now."
