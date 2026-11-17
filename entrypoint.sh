#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Builds an emulated disk array (one loop device per disk image) and starts snapraidd.
set -u
export LAB_DIR=${LAB_DIR:-/lab}
LAB=$LAB_DIR
DATA=${LAB_DATA_DISKS:-4}
PARITY=${LAB_PARITY_DISKS:-2}
SPARE=${LAB_SPARE_DISKS:-2}
SIZE=${LAB_DISK_SIZE_MB:-512}
SIZES=${LAB_DISK_SIZES:-}          # per-disk sizes in MB, e.g. "d1=256 d3=1024 p1=1024 s1=2048"; the others get LAB_DISK_SIZE_MB
UI=${LAB_UI:-commander}
PRESET=${LAB_PRESET:-ready}        # ready: array already set up | blank: only empty disks, set it up from the UI
PARITY_NAMES=(parity 2-parity 3-parity 4-parity 5-parity 6-parity)

log() { echo "[lab] $*"; }

mkdir -p $LAB/img $LAB/etc $LAB/log $LAB/smart /mnt/lab /run/lab/map /run/lab/standby
rm -f /run/lab/map/* /run/lab/standby/*

# The disk list is decided when the lab is created and then kept.
if [ ! -f $LAB/etc/lab-disks ]; then
    {
        for i in $(seq 1 "$DATA"); do echo "d$i"; done
        for i in $(seq 1 "$PARITY"); do echo "p$i"; done
        for i in $(seq 1 "$SPARE"); do echo "s$i"; done
    } > $LAB/etc/lab-disks
    echo "$PRESET" > $LAB/etc/lab-preset
    echo "$SIZES" > $LAB/etc/lab-sizes
fi
[ -f $LAB/etc/lab-sizes ] && SIZES=$(cat $LAB/etc/lab-sizes)
mapfile -t disks < $LAB/etc/lab-disks
PRESET=$(cat $LAB/etc/lab-preset)

# /etc/fstab lives in the lab volume, so what the UI sets up survives a restart.
[ -f $LAB/etc/fstab ] || echo "# lab fstab, maintained by the SnapRAID daemon" > $LAB/etc/fstab
ln -sf $LAB/etc/fstab /etc/fstab

# The container /dev is a snapshot: make sure the loop nodes exist.
for n in $(seq 0 63); do [ -e /dev/loop$n ] || mknod /dev/loop$n b 7 $n 2>/dev/null; done

lab_loops() {
    for f in $LAB/img/*.img; do
        [ -f "$f" ] && losetup -j "$f" -O NAME -n 2>/dev/null
    done
}

release() {
    # pools first, then every filesystem living on a lab disk
    grep -E ' (fuse\.)?mergerfs ' /proc/self/mounts | awk '{print $2}' | while read -r m; do umount "$m" 2>/dev/null; done
    for l in $(lab_loops); do
        grep "^$l" /proc/self/mounts | awk '{print $2}' | sort -r | while read -r m; do umount "$m" 2>/dev/null; done
        losetup -d "$l" 2>/dev/null
    done
}

cleanup() {
    log "stopping"
    [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    release
    exit 0
}
trap cleanup TERM INT

# Loop devices left attached by a previous container run.
release
find /dev/disk/by-uuid -type l -lname '/dev/loop*' -delete 2>/dev/null

le32() { printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)); }
mbr() { # writes an MBR with one Linux partition spanning the image (start at 1 MiB)
    local sectors=$(( $(stat -c %s "$1") / 512 - 2048 ))
    printf "\\x00\\xfe\\xff\\xff\\x83\\xfe\\xff\\xff$(le32 2048)$(le32 $sectors)" | dd of="$1" bs=1 seek=446 conv=notrunc status=none
    printf '\x55\xaa' | dd of="$1" bs=1 seek=510 conv=notrunc status=none
}

# No udev in here: create the partition nodes and publish the filesystem UUIDs
# where SnapRAID looks for them.
nodes() { # loop device
    local loop=$1 base=${1##*/} p devno uuid
    for p in /sys/block/$base/${base}p*; do
        [ -e "$p/dev" ] || continue
        devno=$(cat "$p/dev")
        [ -b "/dev/${p##*/}" ] || mknod "/dev/${p##*/}" b "${devno%%:*}" "${devno##*:}"
        uuid=$(blkid -p -s UUID -o value "/dev/${p##*/}" 2>/dev/null)
        if [ -n "$uuid" ]; then
            mkdir -p /dev/disk/by-uuid
            ln -sf "/dev/${p##*/}" "/dev/disk/by-uuid/$uuid"
        fi
    done
}

size_of() { # disk name -> size in MB
    local kv
    for kv in ${SIZES//,/ }; do [ "${kv%%=*}" = "$1" ] && { echo "${kv#*=}"; return; }; done
    echo "$SIZE"
}

mode=loop
attach() { # name [prepared] -> sets LOOP, and FRESH=1 when the image was just created
    local name=$1 img=$LAB/img/$1.img base
    FRESH=0
    if [ ! -f "$img" ]; then
        truncate -s "$(size_of "$name")M" "$img"
        # A partition table makes the disk look like a real one: SnapRAID resolves
        # the filesystem on loopNp1 back to the "physical" device loopN.
        [ "${2:-}" = prepared ] && { mbr "$img" || return 1; }
        FRESH=1
    fi
    LOOP=$(losetup -fP --show "$img") || return 1
    base=${LOOP##*/}
    if blkid -p -s PTTYPE -o value "$LOOP" >/dev/null 2>&1; then
        for _ in $(seq 1 10); do [ -e "/sys/block/$base/${base}p1/dev" ] && break; sleep 0.1; done
        [ -e "/sys/block/$base/${base}p1/dev" ] || partx -a "$LOOP" 2>/dev/null
        for _ in $(seq 1 10); do [ -e "/sys/block/$base/${base}p1/dev" ] && break; sleep 0.1; done
    fi
    nodes "$LOOP"
    echo "$name" > "/run/lab/map/$base"
}

fresh_disks=()
for d in "${disks[@]}"; do
    prepared=
    case $d in d*|p*) [ "$PRESET" = ready ] && prepared=prepared ;; esac
    if [ $mode = loop ] && attach "$d" $prepared; then
        if [ -n "$prepared" ]; then
            if [ $FRESH = 1 ]; then
                mkfs.ext4 -q -m 0 -L "$d" "${LOOP}p1" && nodes "$LOOP" || { log "ERROR: cannot format $d"; exit 1; }
                fresh_disks+=("$d")
            fi
            # unless the UI gave this place to another disk (a replacement)
            if ! grep -qE "^[^#]+[[:space:]]/mnt/lab/$d[[:space:]]" $LAB/etc/fstab; then
                mkdir -p "/mnt/lab/$d"
                mount "${LOOP}p1" "/mnt/lab/$d" 2>/dev/null || log "$d has no usable filesystem any more, left unmounted"
            fi
        fi
    else
        if [ $mode = loop ]; then
            log "WARNING: loop devices are not usable here, falling back to tmpfs disks (no SMART data, no disk setup, nothing persists)"
            mode=tmpfs
        fi
        case $d in s*) continue ;; esac
        mkdir -p "/mnt/lab/$d"
        mountpoint -q "/mnt/lab/$d" || mount -t tmpfs -o "size=$(size_of "$d")M" "lab-$d" "/mnt/lab/$d" \
            || { log "ERROR: cannot mount anything; run the container with privileged: true"; exit 1; }
        fresh_disks+=("$d")
    fi
done
log "disks ready ($mode mode, preset $PRESET): ${disks[*]}"

# Whatever was set up from the UI in a previous run.
mount -a 2>&1 | sed 's/^/[lab] mount: /'

# SMART profiles, created once and then yours to edit (see `lab smart`).
models=("WDC WD40EFAX-68JH4N1|Western Digital Red|7200|5400" "ST4000VN006-3CW104|Seagate IronWolf|5900|21500" \
        "TOSHIBA HDWG440|Toshiba N300|7200|38900" "Samsung SSD 870 EVO 1TB|Samsung based SSDs|0|9100" \
        "HGST HUS726T4TALA6L4|HGST Ultrastar 7K6|7200|46200" "WDC WD80EFZZ-68BTXN0|Western Digital Red Plus|5640|12800")
k=0
for d in "${disks[@]}"; do
    if [ ! -f "$LAB/smart/$d.env" ]; then
        IFS='|' read -r model family rpm hours <<< "${models[$((k % ${#models[@]}))]}"
        case $d in s*) hours=$((k * 3)) ;; esac   # spares are new
        {
            echo "MODEL=\"$model\""; echo "FAMILY=\"$family\""
            echo "SERIAL=\"LAB$(printf '%04d' $((1000 + k * 37)))${d^^}\""
            echo "RPM=$rpm"; echo "TEMP=$((31 + (k * 3) % 9))"; echo "POWER_ON_HOURS=$hours"
            echo "START_STOP=$((40 + k * 13))"; echo "POWER_CYCLE=$((38 + k * 11))"; echo "LOAD_CYCLE=$((900 + k * 410))"
            echo "REALLOCATED=0"; echo "PENDING=0"; echo "UNCORRECTABLE=0"; echo "CRC_ERRORS=0"; echo "REPORTED_UNCORRECT=0"
            [ "$rpm" = 0 ] && echo "WEAR_LEVEL=094"
            echo "FAILING=0"
        } > "$LAB/smart/$d.env"
        # One ageing disk, so the health pages have something to say.
        [ "$d" = d3 ] && sed -i 's/^REALLOCATED=0/REALLOCATED=8/; s/^TEMP=.*/TEMP=44/' "$LAB/smart/$d.env"
    fi
    k=$((k + 1))
done

# Array configuration, written once: afterwards it belongs to you and to the UI.
if [ "$PRESET" = ready ] && [ ! -f $LAB/etc/snapraid.conf ]; then
    {
        echo "# SnapRAID lab array"
        for i in $(seq 1 "$PARITY"); do echo "${PARITY_NAMES[$((i - 1))]} /mnt/lab/p$i/snapraid.${PARITY_NAMES[$((i - 1))]}"; done
        echo "content $LAB/etc/snapraid.content"
        for i in $(seq 1 "$DATA"); do [ "$i" -le $((PARITY + 1)) ] && echo "content /mnt/lab/d$i/snapraid.content"; done
        for i in $(seq 1 "$DATA"); do echo "data d$i /mnt/lab/d$i"; done
        echo "exclude *.tmp"; echo "exclude /lost+found/"
        echo "autosave 1"
    } > $LAB/etc/snapraid.conf
fi
if [ ! -f $LAB/etc/snapraidd.conf ]; then
    cat > $LAB/etc/snapraidd.conf <<CONF
# SnapRAID Daemon lab configuration (see snapraidd.conf.example for every option)
sys_engine = /usr/bin/snapraid
sys_log_directory = $LAB/log
sys_log_retention_days = 120
net_enabled = 1
# all interfaces of the container; docker publishes it on the Mac's localhost only
net_port = 7627
net_security_headers = 1
net_allowed_origin = self
net_config_full_access = 1
# disks, mounts, pools and snapraid.conf can be changed from the UI
net_storage_admin = 1
# storage administration wants the daemon protected: here only private addresses
# (the docker network) are let in. On a real machine prefer net_auth_credential.
net_acl = +127.0.0.1,+10.0.0.0/8,+172.16.0.0/12,+192.168.0.0/16
net_web_root = /ui/commander
check_updates = 0
maintenance_schedule = 02:00
sync_threshold_deletes = 50
sync_threshold_updates = 100
scrub_percentage = 8
scrub_older_than = 10
touch_zero_subseconds = 1
probe_interval_minutes = 1
spindown_idle_minutes = 15
notify_syslog_enabled = 0
notify_result_level = warning
notify_differences = 1
CONF
fi
grep -q '^net_acl' $LAB/etc/snapraidd.conf || sed -i 's|^net_web_root = .*|net_acl = +127.0.0.1,+10.0.0.0/8,+172.16.0.0/12,+192.168.0.0/16\n&|' $LAB/etc/snapraidd.conf
grep -q '^net_storage_admin' $LAB/etc/snapraidd.conf || sed -i 's|^net_web_root = .*|net_storage_admin = 1\n&|' $LAB/etc/snapraidd.conf
sed -i "s|^net_web_root = .*|net_web_root = /ui/$UI|" $LAB/etc/snapraidd.conf

# Sample content on new data disks, a first sync, then some changes left pending.
seeded=0
for d in "${fresh_disks[@]}"; do
    case $d in d*) lab seed "$d"; seeded=1 ;; esac
done
if [ $seeded = 1 ] && [ ! -f $LAB/etc/snapraid.content ]; then
    log "first sync of the new array"
    snapraid -c $LAB/etc/snapraid.conf -q sync >/dev/null 2>$LAB/log/first-sync.err || log "first sync failed, see $LAB/log/first-sync.err"
    lab churn >/dev/null
fi

log "starting snapraidd, UI '$UI' on http://localhost:7627"
# -N: serve the UI files straight from /ui/<name> without caching, so edits show up on reload
snapraidd -f -N -c $LAB/etc/snapraidd.conf -C $LAB/etc/snapraid.conf -p /run/snapraidd.pid &
DAEMON_PID=$!
if [ "${LAB_RUN_TESTS:-0}" = 1 ]; then
    # run the API tests against this lab, then stop with their result
    /usr/local/share/lab/tests/${LAB_TEST:-api-test.sh}
    rc=$?
    log "tests ended with $rc failures"
    kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null
    DAEMON_PID=
    trap - TERM INT
    ( release ) >/dev/null 2>&1
    exit $rc
fi
wait $DAEMON_PID
rc=$?
log "snapraidd exited with $rc"
DAEMON_PID=
trap - TERM INT
( release ) >/dev/null 2>&1
exit $rc
