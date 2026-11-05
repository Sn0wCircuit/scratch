#!/bin/bash
set -e

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

# --- Questions ---
lsblk -d -o NAME,SIZE,MODEL
read -rp "Disk name (e.g. nvme0n1, sda): " DISK
case $DISK in *[0-9]) P=p ;; *) P= ;; esac
part() { echo "/dev/$DISK$P$1"; }

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
read -rp "Hostname [archlinux]: " NEWHOST;  NEWHOST=${NEWHOST:-archlinux}
read -rp "Username [shihab]: " NEWUSER;  NEWUSER=${NEWUSER:-shihab}
read -rsp "Root password: " ROOT_PASS; echo
read -rsp "User password: " USER_PASS; echo

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
echo "EFI:      $EFI (format: $FORMAT_EFI)"
echo "Boot:     $BOOT (format)"
echo "Root:     $ROOT (format)"
echo "Extra:    ${EXTRA:-none}${EXTRA:+ -> $EXTRA_MNT}"
echo "Hostname: $NEWHOST"
echo "Username: $NEWUSER"
echo "Root pw:  $ROOT_PASS"
echo "User pw:  $USER_PASS"
echo "CachyOS:  $CPU_LEVEL"
read -rp "Proceed? (Y/n): " OK
[[ $OK == [nN]* ]] && exit 1

# --- Mirrors + CachyOS repos in the LIVE system ---
# Done before formatting so a network/key problem aborts before touching disks.
cat > /etc/pacman.d/mirrorlist <<'EOF'
## Bangladesh
Server = https://mirror.xeonbd.com/archlinux/$repo/os/$arch
Server = http://mirror.xeonbd.com/archlinux/$repo/os/$arch
Server = https://mirror.limda.net/archlinux/$repo/os/$arch
Server = http://mirror.limda.net/archlinux/$repo/os/$arch
EOF

if [ "$CPU_LEVEL" != none ]; then
    import_cachy_key
    # Installs keyring, mirrorlists and CachyOS's pacman fork (needed for the
    # $arch_v3/$arch_v4 mirror variables and the automatic architecture check)
    pacman -U --noconfirm --needed "${CACHY_PKGS_U[@]}"
    add_cachyos_repos /etc/pacman.conf "$CPU_LEVEL"
    pacman -Sy
    echo "Live pacman: $(pacman -Q pacman)"
    pacman -Si linux | grep -E '^(Repository|Version|Architecture)' || true
fi

# --- Format & mount ---
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
if [ "$FORMAT_EFI" = y ]; then mkfs.fat -F 32 "$EFI"; fi
mkfs.ext4 -F "$BOOT"
mkfs.ext4 -F "$ROOT"
mount "$ROOT" /mnt
mount -o fmask=0177,dmask=0077 --mkdir "$EFI" /mnt/efi
mount --mkdir "$BOOT" /mnt/boot
if [ "$FORMAT_EFI" = n ]; then
    rm -rf /mnt/efi/loader/ /mnt/efi/EFI/Boot/ /mnt/efi/EFI/systemd/
fi

# --- Base install ---
mkdir -p /mnt/etc && touch /mnt/etc/vconsole.conf
PACSTRAP_PKGS=(base linux linux-firmware)
if [ "$CPU_LEVEL" != none ]; then
    # cachyos/pacman: make sure the fork (not a generic rebuild) lands in the new system;
    # the keyring + mirrorlists are required by the repos we add to its pacman.conf below
    PACSTRAP_PKGS+=(cachyos/pacman cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist)
fi
pacstrap -K /mnt "${PACSTRAP_PKGS[@]}"

# --- CachyOS repos + keyring in the NEW system (persists after reboot) ---
if [ "$CPU_LEVEL" != none ]; then
    [ -f /mnt/etc/pacman.conf ] || cp /etc/pacman.conf /mnt/etc/pacman.conf
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

# --- Fstab ---
genfstab -U /mnt > /mnt/etc/fstab
if [ -n "$EXTRA" ]; then
    printf '\n# %s LABEL=%s\nUUID=%s\t%s\tntfs\trw,nofail,nosuid,nodev,relatime,uid=1000,gid=1000\t0\t0\n' \
        "$EXTRA" "$(lsblk -n -o LABEL "$EXTRA")" "$(blkid -s UUID -o value "$EXTRA")" "$EXTRA_MNT" >> /mnt/etc/fstab
    mkdir -p "/mnt$EXTRA_MNT"
fi

# --- Chroot setup ---
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT")
cat > /mnt/setup.sh <<EOF
#!/bin/bash
set -e
sed -i '/^HOOKS=/ s/systemd/systemd plymouth/' /etc/mkinitcpio.conf
pacman -S --needed --noconfirm base-devel intel-ucode networkmanager micro pacman-contrib bash-completion plymouth zram-generator
systemctl enable NetworkManager
echo -e "[zram0]\nzram-size = 8192\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
curl -fL -o /usr/share/kbd/consolefonts/ter-122b.psf.gz https://github.com/Sn0wCircuit/scratch/raw/refs/heads/main/ter-122b.psf.gz
echo "FONT=ter-122b" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Asia/Dhaka /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$NEWHOST" > /etc/hostname
useradd -m -G wheel $NEWUSER
sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
bootctl --esp-path=/efi --boot-path=/boot install
echo -e "title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=PARTUUID=$ROOT_PARTUUID rw zswap.enabled=0 quiet splash" > /boot/loader/entries/arch.conf
sed -i 's/^#timeout 3/timeout 3/' /efi/loader/loader.conf
sed -i '1i default arch.conf' /efi/loader/loader.conf
EOF
arch-chroot -S /mnt /bin/bash /setup.sh
rm /mnt/setup.sh

# Passwords set outside the script file so special characters are safe
echo "root:$ROOT_PASS" | arch-chroot /mnt chpasswd
echo "$NEWUSER:$USER_PASS" | arch-chroot /mnt chpasswd

# --- Finalize: ext4 EFI driver ---
mkdir -p /mnt/efi/EFI/systemd/drivers
curl -fL -o /mnt/efi/EFI/systemd/drivers/ext4_x64.efi https://github.com/Sn0wCircuit/scratch/raw/refs/heads/main/ext4_x64.efi
umount -R /mnt
echo "Done! Reboot now."
