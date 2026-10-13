#!/bin/bash
# Clone lumine's SD card onto an SSD (USB-attached or on an NVMe HAT) so the
# box can boot from it: `just box-clone-ssd /dev/sdX` (see docs/care-box.md).
#
# File-level, not dd: only the used space crosses the (possibly USB 2) link,
# and the target gets its own partition IDs, so the untouched SD card stays a
# working fallback and both can be plugged in at once without root= clashes.
# A first rsync runs live; a second, short one runs with postgres, redis,
# VersityGW and CARE stopped so the copy of their data is consistent, then
# they start again (or, with --poweroff, the box powers off so nothing is
# written to the SD after the copy: pull the card and power on).
#
# Usage: clone-to-ssd.sh <disk> [--force] [--poweroff]
#   --force     overwrite a disk that already has partitions/signatures
#   --poweroff  power off after the copy instead of restarting the services
set -euo pipefail

die() { echo "clone-to-ssd: $*" >&2; exit 1; }

dev=${1:-}
[ -n "$dev" ] || die "usage: clone-to-ssd.sh <disk> [--force] [--poweroff]"
shift
force='' poweroff=''
for a in "$@"; do
    case $a in
    --force) force=1 ;;
    --poweroff) poweroff=1 ;;
    *) die "unknown flag $a" ;;
    esac
done

[ "$(id -u)" = 0 ] || die "run as root"
src=/dev/mmcblk0
[ "$(findmnt -no SOURCE /)" = "${src}p2" ] || die "/ is not on ${src}p2; only cloning a running SD-card system is supported"
[ -b "$dev" ] && [ "$(lsblk -dno TYPE "$dev")" = disk ] || die "$dev is not a disk"
[ "$dev" != "$src" ] || die "$dev is the SD card"
! lsblk -no MOUNTPOINTS "$dev" | grep -q . || die "$dev (or a partition on it) is mounted"
if [ -z "$force" ] && [ -n "$(wipefs -n "$dev")$(lsblk -no FSTYPE "$dev" | tr -d '[:space:]')" ]; then
    die "$dev is not empty (pass --force to overwrite it):"$'\n'"$(lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev")"
fi
used=$(df --output=used -B1 / | tail -1)
size=$(blockdev --getsize64 "$dev")
[ "$size" -gt $((used + 2 * 1024 ** 3)) ] || die "$dev ($size bytes) is too small for ${used} bytes used"

part() { case $dev in *[0-9]) echo "${dev}p$1" ;; *) echo "$dev$1" ;; esac; }
p1=$(part 1) p2=$(part 2)
mnt=/mnt/ssd-clone
data_units=(care.target care-api.service care-worker.service care-beat.service versitygw.service redis-server.service postgresql.service)
stopped=

cleanup() {
    umount -q "$mnt/boot/firmware" 2>/dev/null || true
    umount -q "$mnt" 2>/dev/null || true
    # Never leave CARE down because the clone failed half-way.
    if [ -n "$stopped" ]; then
        echo "starting services again"
        systemctl start postgresql.service redis-server.service versitygw.service care.target
    fi
}
trap cleanup EXIT

echo "== $dev: $(lsblk -dno SIZE,TRAN,MODEL "$dev") <- $src ($((used / 1024 ** 2)) MiB used)"
start=$SECONDS

# Same layout as the Raspberry Pi OS image on the SD card (MBR, FAT32 boot at
# 8 MiB, ext4 root filling the rest); sfdisk picks a new random disk id.
wipefs -qa "$dev"
sfdisk -q --wipe always --wipe-partitions always "$dev" <<EOF
label: dos
start=16384, size=1048576, type=c
start=1064960, type=83
EOF
udevadm settle
mkfs.vfat -F 32 -n bootfs "$p1" >/dev/null
mkfs.ext4 -F -q -L rootfs "$p2"

mkdir -p "$mnt"
mount "$p2" "$mnt"
mkdir -p "$mnt/boot/firmware"
mount "$p1" "$mnt/boot/firmware"

# -x stays on / (skips /proc, /sys, /dev, /run, the tmpfs /tmp: their mount
# points are created empty). /boot/firmware is excluded rather than left to
# -x so --delete can't empty the target's (mounted) boot partition; it gets
# its own pass. -AX: VersityGW keeps S3 metadata in user.* xattrs.
# /var/swap is recreated below, not copied.
copy() {
    local rc=0
    rsync -aHAXx --numeric-ids --delete --info=stats1 \
        --exclude=/var/swap --exclude='/boot/firmware/*' --exclude="$mnt/*" \
        / "$mnt/" || rc=$?
    # 24 = files vanished mid-copy: expected on the live pass only.
    [ "$rc" = 0 ] || { [ "$rc" = 24 ] && [ "$1" = live ]; } || die "rsync / failed ($rc)"
    rsync -rt --modify-window=1 --delete --info=stats1 /boot/firmware/ "$mnt/boot/firmware/"
}

echo "== pass 1 (live)"
copy live
echo "== pass 2 (data services stopped)"
stopped=1
systemctl stop "${data_units[@]}"
t=$SECONDS
copy final
sync
if [ -z "$poweroff" ]; then
    systemctl start postgresql.service redis-server.service versitygw.service care.target
    stopped=
    echo "services were down for $((SECONDS - t)) s"
fi

# The target's own partition ids, in both places that name the root.
old=$(sfdisk --disk-id "$src" | sed 's/^0x//')
new=$(sfdisk --disk-id "$dev" | sed 's/^0x//')
sed -i "s/PARTUUID=$old-/PARTUUID=$new-/g" "$mnt/boot/firmware/cmdline.txt" "$mnt/etc/fstab"
grep -q "root=PARTUUID=$new-02 " "$mnt/boot/firmware/cmdline.txt" || die "cmdline.txt root= not rewritten"
[ "$(grep -c "PARTUUID=$new-0[12]" "$mnt/etc/fstab")" = 2 ] || die "fstab not rewritten"

# As rpi-resize-swap-file creates it (fallocate, no data written).
swap_mib=$(($(stat -c %s /var/swap) / 1024 ** 2))
(umask 077 && fallocate --posix --length "${swap_mib}M" "$mnt/var/swap")
mkswap -q --uuid clear --label origin:rpi-swap "$mnt/var/swap"

echo "== $dev: $(df -h --output=used "$mnt" | tail -1 | tr -d ' ') on root, PARTUUID $new-0{1,2}"
echo "cmdline.txt: $(cat "$mnt/boot/firmware/cmdline.txt")"
grep PARTUUID "$mnt/etc/fstab"

umount "$mnt/boot/firmware" "$mnt"
fsck.vfat -n "$p1" >/dev/null
e2fsck -fn "$p2" >/dev/null
echo "== fsck clean; done in $((SECONDS - start)) s"

if [ -n "$poweroff" ]; then
    stopped=
    echo "powering off: remove the SD card, then power on to boot from $dev"
    systemctl poweroff
fi
