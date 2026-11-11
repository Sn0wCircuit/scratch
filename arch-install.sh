#!/bin/bash
set -e

# Same as the official cachyos-repo.sh: force English/C output so the grep-based checks
# on tool output (ld.so --help) can't be broken by localization.
export LC_MESSAGES=C
export LANG=C

timedatectl set-ntp true

# --- CachyOS repo settings (taken from CachyOS's official cachyos-repo.sh) ---
# If a download 404s one day, bump these to the versions listed on
# https://wiki.cachyos.org/features/optimized_repos/
CACHY_KEY=F3B607488DB35A47
CACHY_URL=https://mirror.cachyos.org/repo/x86_64/cachyos

# Highest x86-64 level this CPU supports, same check as the official script:
# /lib/ld-linux-x86-64.so.2 --help reports it as "(supported, searched)".
# znver4 is never auto-detected (the official check needs gcc, which the live ISO
# does not have): choose it manually at the prompt on an AMD Zen 4/5 CPU.
detect_level() {
    local out
    out=$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null || true)
    if grep -q 'x86-64-v4 (supported, searched)' <<<"$out"; then echo v4
    elif grep -q 'x86-64-v3 (supported, searched)' <<<"$out"; then echo v3
    else echo none
    fi
}
# none < v3 < v4 = znver4 (znver4 needs x86-64-v4, same as the official script)
level_rank() {
    case $1 in
        none) echo 0 ;;
        v3) echo 1 ;;
        v4|znver4) echo 2 ;;
    esac
}
cachy_sig_ok() {
    local tmp rc; tmp=$(mktemp)
    if curl -fsSL --retry 2 "$1.sig" -o "$tmp" 2>/dev/null \
       && [ -s "$tmp" ] && ! grep -aqiE '<html|<!doctype' "$tmp"; then rc=0; else rc=1; fi
    rm -f "$tmp"; return $rc
}

# Resolve the newest filenames from the mirror's directory listing
cachy_resolve_pkgs() {
    local listing p f
    listing=$(curl -fsSL --retry 3 "$CACHY_URL/") || { echo "Cannot fetch $CACHY_URL/" >&2; return 1; }
    CACHY_PKGS_U=()
    for p in cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist pacman; do
        f=$(grep -oP "(?<=href=\")${p}-[0-9][^\"/]*-(any|x86_64)\.pkg\.tar\.zst(?=\")" <<<"$listing" | sort -uV | tail -n1 || true)
        [ -n "$f" ] || { echo "No '$p' package found in $CACHY_URL/" >&2; return 1; }
        cachy_sig_ok "$CACHY_URL/$f" || { echo "Missing/invalid signature for $f" >&2; return 1; }
        CACHY_PKGS_U+=("$CACHY_URL/$f")
    done
    printf 'Resolved: %s\n' "${CACHY_PKGS_U[@]##*/}"
}


# tweak_pacman_conf <pacman.conf>
# Color, ILoveCandy, VerbosePkgLists, DisableDownloadTimeout, ParallelDownloads = 10,
# NoExtract for the hardcoded mirrorlists, CheckSpace off and [multilib]. Idempotent.
# NoExtract (not NoUpgrade, which still drops a .pacnew) makes pacman never extract the
# Arch and CachyOS mirrorlists from their packages, so our hardcoded lists are never
# replaced and no .pacnew files appear. The lists are written after the package installs.
tweak_pacman_conf() {
    local conf=$1 opt key
    # Not just uncommenting: stock Arch pacman.conf lacks some of these lines (e.g.
    # ILoveCandy), so a plain s/^#X/X/ silently does nothing. For each option, drop any
    # existing line (commented or not, any value) and add one active line under [options].
    # Each add goes right under [options], so the list is in reverse of the final order.
    for opt in "NoExtract = etc/pacman.d/mirrorlist etc/pacman.d/cachyos-mirrorlist etc/pacman.d/cachyos-v3-mirrorlist etc/pacman.d/cachyos-v4-mirrorlist" "ParallelDownloads = 10" DisableDownloadTimeout VerbosePkgLists ILoveCandy Color; do
        key=${opt%% *}
        sed -i "/^#\?$key\b/d" "$conf"
        sed -i "/^\[options\]/a $opt" "$conf"
    done
    sed -i 's/^CheckSpace/#CheckSpace/' "$conf"
    sed -i 's/^#\[multilib\]/[multilib]/' "$conf"
    sed -i '/^\[multilib\]/{n;s/^#//}' "$conf"
}

# add_cachyos_repos <pacman.conf> <znver4|v4|v3|none>
# Removes any existing [cachyos*] sections, then inserts the CachyOS repos
# ABOVE [core] (required: first repo containing a package wins). Idempotent.
# Blocks are exactly the official ones (install-repo.awk / install-v4-repo.awk /
# install-znver4-repo.awk, and the wiki's x86-64-only entry):
#   v3     : [cachyos-v3] [cachyos-core-v3] [cachyos-extra-v3] [cachyos]  (cachyos-v3-mirrorlist)
#   v4     : [cachyos-v4] [cachyos-core-v4] [cachyos-extra-v4] [cachyos]  (cachyos-v4-mirrorlist)
#   znver4 : [cachyos-znver4] [cachyos-core-znver4] [cachyos-extra-znver4] [cachyos]
#            (also cachyos-v4-mirrorlist, there is no znver4 mirrorlist)
#   none   : [cachyos] only (cachyos-mirrorlist)
add_cachyos_repos() {
    local conf=$1 level=$2 blockfile ml
    case $level in
        znver4) ml=v4 ;;
        *)      ml=$level ;;
    esac
    blockfile=$(mktemp)
    {
        if [ "$level" != none ]; then
            printf '[cachyos-%s]\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$ml"
            printf '[cachyos-core-%s]\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$ml"
            printf '[cachyos-extra-%s]\nInclude = /etc/pacman.d/cachyos-%s-mirrorlist\n\n' "$level" "$ml"
        fi
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
    if ! grep -q '^\[cachyos\]' "$conf" \
       || { [ "$level" != none ] && ! grep -q "^\[cachyos-core-$level\]" "$conf"; }; then
        echo "Failed to add CachyOS repos to $conf" >&2; exit 1
    fi
}

# Trust the CachyOS signing key in the live system's keyring
import_cachy_key() {
    local f
    # wait (max 60s) for the live ISO's keyring init
    if systemctl cat pacman-init.service >/dev/null 2>&1; then
        for _ in $(seq 60); do systemctl is-active --quiet pacman-init.service && break; sleep 1; done
    else
        for _ in $(seq 60); do [ -s /etc/pacman.d/gnupg/trustdb.gpg ] && break; sleep 1; done
    fi
    # Key comes from the keyring package on the CachyOS mirror (no keyserver needed)
    f=$(curl -fsSL --retry 3 "$CACHY_URL/" | grep -oP '(?<=href=")cachyos-keyring-[0-9][^"/]*-any\.pkg\.tar\.zst(?=")' | sort -uV | tail -n1)
    [ -n "$f" ] || { echo "Cannot find cachyos-keyring on mirror" >&2; exit 1; }
    rm -rf /tmp/ck; mkdir -p /tmp/ck
    curl -fsSL --retry 3 "$CACHY_URL/$f" -o /tmp/ck.pkg.tar.zst
    bsdtar -xf /tmp/ck.pkg.tar.zst -C /tmp/ck
    pacman-key --add /tmp/ck/usr/share/pacman/keyrings/cachyos.gpg
    pacman-key --lsign-key "$CACHY_KEY"
}


# Hardcoded mirrorlists (no mirror ranking). <root> is '' for the live system, /mnt for the new one.
# Quoted heredocs: $repo and $arch must stay literal, pacman expands them.
write_arch_mirrorlist() {
    mkdir -p "$1/etc/pacman.d"
    cat > "$1/etc/pacman.d/mirrorlist" <<'ARCH_MIRRORS'
## Bangladesh
Server = https://mirror.xeonbd.com/archlinux/$repo/os/$arch
Server = http://mirror.xeonbd.com/archlinux/$repo/os/$arch
Server = https://mirror.limda.net/archlinux/$repo/os/$arch
Server = http://mirror.limda.net/archlinux/$repo/os/$arch
## Worldwide
Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://ftpmirror.infania.net/mirror/archlinux/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = http://mirror.rackspace.com/archlinux/$repo/os/$arch
ARCH_MIRRORS
}
# cachyos-mirrorlist: limda first, then CachyOS's own global tier-1 CDNs as fallback; pacman
# tries the servers top to bottom. The v3/v4 lists are derived from it exactly like the
# official cachyos-rate-mirrors does (/$arch/ -> /$arch_v3/ and /$arch_v4/, variables provided
# by CachyOS's pacman fork), so all three always match.
write_cachyos_mirrorlist() {
    local d="$1/etc/pacman.d"
    mkdir -p "$d"
    cat > "$d/cachyos-mirrorlist" <<'CACHY_MIRRORS'
## Bangladesh
Server = https://mirror.limda.net/cachy/repo/$arch/$repo
Server = http://mirror.limda.net/cachy/repo/$arch/$repo
## CDN77 (World Wide Datacenters)
## tier=1 code=GLOBAL
Server = https://cdn77.cachyos.org/repo/$arch/$repo
## Rerouted to mirror
## tier=1 code=GLOBAL
Server = https://cdn.cachyos.org/repo/$arch/$repo
## tier=1 code=GLOBAL
Server = https://cdn.lansing2600.org/cachyos/repo/$arch/$repo
## tier=2 code=GLOBAL
Server = https://mirror.krfoss.org/cachyos/repo/$arch/$repo
## tier=2 code=GLOBAL
Server = https://mirror5.krfoss.org/cachyos/repo/$arch/$repo
## tier=2 code=GLOBAL
Server = https://cachyos.mirror.sahil.world/repo/$arch/$repo
CACHY_MIRRORS
    sed 's|/$arch/|/$arch_v3/|g' "$d/cachyos-mirrorlist" > "$d/cachyos-v3-mirrorlist"
    sed 's|/$arch/|/$arch_v4/|g' "$d/cachyos-mirrorlist" > "$d/cachyos-v4-mirrorlist"
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

DETECTED_LEVEL=$(detect_level)
echo
echo "Detected CPU level: $DETECTED_LEVEL"
if [ "$DETECTED_LEVEL" = v4 ]; then
    echo "NOTE: Intel 12th gen (Alder Lake) and newer can report v4 but cannot run AVX-512."
    echo "      If your CPU is one of those, choose v3."
    echo "NOTE: on an AMD Zen 4/5 CPU, choose znver4 (it cannot be auto-detected here)."
fi
read -rp "CachyOS optimized repos: znver4 / v4 / v3 / none [$DETECTED_LEVEL]: " CPU_LEVEL
CPU_LEVEL=${CPU_LEVEL:-$DETECTED_LEVEL}
case $CPU_LEVEL in znver4|v4|v3|none) ;; *) echo "Invalid level: $CPU_LEVEL"; exit 1 ;; esac
# Same refusal as the official script (add_specific_repo): a level the CPU does not
# report as supported is not added. v3 needs x86-64-v3, v4 and znver4 need x86-64-v4.
if [ "$(level_rank "$CPU_LEVEL")" -gt "$(level_rank "$DETECTED_LEVEL")" ]; then
    echo "This CPU does not report support for '$CPU_LEVEL' (detected: $DETECTED_LEVEL)."
    exit 1
fi

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

# --- Hardcoded Arch mirrorlist in the LIVE system ---
write_arch_mirrorlist ""

# --- CachyOS repos in the LIVE system ---
# Done before formatting so a network/key problem aborts before touching disks.
import_cachy_key
cachy_resolve_pkgs
# Live ISO workaround: CachyOS's pacman fork can need a newer libcrypto than the ISO has,
# so it is NOT installed in the live system (pacstrap still installs it into the new one).
# Only the keyring and mirrorlists go in here; the live stock pacman gets literal
# x86_64_v3/x86_64_v4 paths and a multi-value Architecture instead of the fork's variables.
LIVE_PKGS=()
for u in "${CACHY_PKGS_U[@]}"; do [[ ${u##*/} == pacman-* ]] || LIVE_PKGS+=("$u"); done
pacman -U --noconfirm --needed "${LIVE_PKGS[@]}"
# after the -U above, which installs the packages' default mirrorlists
write_cachyos_mirrorlist ""
sed -i 's|\$arch_v3|x86_64_v3|g' /etc/pacman.d/cachyos-v3-mirrorlist
sed -i 's|\$arch_v4|x86_64_v4|g' /etc/pacman.d/cachyos-v4-mirrorlist
add_cachyos_repos /etc/pacman.conf "$CPU_LEVEL"
case $CPU_LEVEL in
    v3)        LIVE_ARCH="x86_64 x86_64_v3" ;;
    v4|znver4) LIVE_ARCH="x86_64 x86_64_v3 x86_64_v4" ;;
    *)         LIVE_ARCH="x86_64" ;;
esac
sed -i "s/^Architecture[[:space:]]*=.*/Architecture = $LIVE_ARCH/" /etc/pacman.conf
echo "Live pacman: $(pacman -Q pacman) (stock, Architecture = $LIVE_ARCH)"

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
# cachyos/pacman: make sure the fork (not a generic rebuild) lands in the new system;
# the keyring + mirrorlists are required by the repos we add to its pacman.conf below
# (the official script installs all five packages for every level, including x86-64-only)
PACSTRAP_PKGS=(base linux-cachyos linux-firmware)
PACSTRAP_PKGS+=(cachyos/pacman cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist)
pacstrap -K /mnt "${PACSTRAP_PKGS[@]}"

# --- pacman.conf tweaks in the NEW system ---
# pacstrap does not use this file. It only exists once pacstrap has installed pacman;
# the tweak applies from the arch-chroot stage onward and to the installed system.
tweak_pacman_conf /mnt/etc/pacman.conf

# --- CachyOS repos + keyring in the NEW system (persists after reboot) ---
[ -f /mnt/etc/pacman.conf ] || cp /etc/pacman.conf /mnt/etc/pacman.conf
# hardcoded mirrorlists; written after pacstrap, which installed the packages' default
# CachyOS mirrorlists and copied the host's Arch mirrorlist
write_arch_mirrorlist /mnt
write_cachyos_mirrorlist /mnt
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
echo "Done! Reboot: sudo systemctl reboot"
