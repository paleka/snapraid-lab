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
MEDIA=${LAB_MEDIA_DATA_DISKS:-0}   # data disks (m1..mN) of a second array named "media", with one parity disk (q1)
SCRATCH=${LAB_SCRATCH_DISKS:-0}    # disks (x1..xN) formatted and mounted, but in no array
POOLS=${LAB_POOLS:-0}              # 1: a mergerfs pool for every array, and one for the scratch disks
SIZE=${LAB_DISK_SIZE_MB:-512}
SIZES=${LAB_DISK_SIZES:-}          # per-disk sizes in MB, e.g. "d1=256 d3=1024 p1=1024 s1=2048"; the others get LAB_DISK_SIZE_MB
FLASH=${LAB_FLASH_DATA_DISKS:-0}    # data disks (f1..fN) of a third array named "flash", with one parity disk (g1)
SPLIT=${LAB_MEDIA_SPLIT_PARITY:-0} # 1: the parity of the array "media" is split over two disks (q1, q2), each smaller than its data disks
USB=${LAB_USB_DISKS:-0}            # disks (u1..uN) mounted on their own: in no array and in no pool
TYPES=${LAB_DISK_TYPES:-}          # per-disk kind, e.g. "d1=hdd d2=smr d3=sas d4=ssd f1=nvme u1=usb"; the others get a default
FSS=${LAB_DISK_FS:-}               # per-disk filesystem, e.g. "d2=xfs f1=btrfs"; the others get ext4
SHOWCASE=${LAB_SHOWCASE:-0}        # 1: the configurations use the less common options of SnapRAID and of the daemon
AUTH=${LAB_AUTH:-}                 # user:password, to try the login of the daemon (net_auth_credential)
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
        if [ "$MEDIA" -gt 0 ]; then
            for i in $(seq 1 "$MEDIA"); do echo "m$i"; done
            echo "q1"
            [ "$SPLIT" = 1 ] && echo "q2"
        fi
        if [ "$FLASH" -gt 0 ]; then
            for i in $(seq 1 "$FLASH"); do echo "f$i"; done
            echo "g1"
        fi
        for i in $(seq 1 "$SCRATCH"); do echo "x$i"; done
        for i in $(seq 1 "$USB"); do echo "u$i"; done
    } > $LAB/etc/lab-disks
    echo "$PRESET" > $LAB/etc/lab-preset
    echo "$SIZES" > $LAB/etc/lab-sizes
    echo "$TYPES" > $LAB/etc/lab-types
    echo "$FSS" > $LAB/etc/lab-fs
    echo "$SHOWCASE" > $LAB/etc/lab-showcase
fi
[ -f $LAB/etc/lab-sizes ] && SIZES=$(cat $LAB/etc/lab-sizes)
[ -f $LAB/etc/lab-types ] && TYPES=$(cat $LAB/etc/lab-types)
[ -f $LAB/etc/lab-fs ] && FSS=$(cat $LAB/etc/lab-fs)
[ -f $LAB/etc/lab-showcase ] && SHOWCASE=$(cat $LAB/etc/lab-showcase)
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

lookup() { # "name=value ..." name -> value, or nothing
    local kv
    for kv in ${1//,/ }; do [ "${kv%%=*}" = "$2" ] && { echo "${kv#*=}"; return; }; done
}

fs_of() { # disk name -> filesystem. xfs needs 300 MB, btrfs 128 MB: a smaller disk gets ext4
    local fs; fs=$(lookup "$FSS" "$1")
    case $fs in
    xfs) [ "$(size_of "$1")" -ge 300 ] || fs= ;;
    btrfs) [ "$(size_of "$1")" -ge 128 ] || fs= ;;
    ext4) ;;
    *) fs= ;;
    esac
    command -v "mkfs.${fs:-ext4}" >/dev/null || fs=
    echo "${fs:-ext4}"
}

format() { # disk name, device
    case $(fs_of "$1") in
    xfs) mkfs.xfs -q -f -L "$1" "$2" ;;
    btrfs) mkfs.btrfs -q -f -L "$1" "$2" >/dev/null ;;
    *) mkfs.ext4 -q -m 0 -L "$1" "$2" ;;
    esac
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
    case $d in d*|p*|m*|q*|f*|g*|x*|u*) [ "$PRESET" = ready ] && prepared=prepared ;; esac
    if [ $mode = loop ] && attach "$d" $prepared; then
        if [ -n "$prepared" ]; then
            if [ $FRESH = 1 ]; then
                format "$d" "${LOOP}p1" && nodes "$LOOP" || { log "ERROR: cannot format $d"; exit 1; }
                fresh_disks+=("$d")
                # like a machine set up with care: mounted at boot by UUID, and a missing disk does not stop the boot
                if [ "$SHOWCASE" = 1 ]; then
                    echo "UUID=$(blkid -p -s UUID -o value "${LOOP}p1") /mnt/lab/$d $(fs_of "$d") defaults,noatime,nofail 0 0" >> $LAB/etc/fstab
                    mkdir -p "/mnt/lab/$d"
                fi
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

# One pool for every array and one for the disks of no array, made once: then they are yours and of the UI.
if [ "$PRESET" = ready ] && [ "$POOLS" = 1 ] && [ $mode = loop ] && command -v mergerfs >/dev/null && [ ! -f $LAB/etc/lab-pools ]; then
    touch $LAB/etc/lab-pools
    # through the helper of FUSE, that drops "nofail" before mergerfs sees it
    fstype=fuse.mergerfs; command -v mount.fuse >/dev/null || { command -v mount.mergerfs >/dev/null && fstype=mergerfs; }
    add_pool() { # mountpoint prefix [create policy] [more options]
        local branches=
        for d in "${disks[@]}"; do case $d in $2*) branches="${branches:+$branches:}/mnt/lab/$d" ;; esac; done
        [ -n "$branches" ] || return
        mkdir -p "$1"
        echo "$branches $1 $fstype cache.files=off,category.create=${3:-pfrd},${4:+$4,}minfreespace=10M,fsname=mergerfs,allow_other,nofail 0 0" >> $LAB/etc/fstab
    }
    if [ "$SHOWCASE" = 1 ]; then
        # the options the Storage page gives a new pool, and a different placement of new files in every pool:
        # by free space weighted at random, on the disk with most free space, next to the folder that exists
        full=func.getattr=newest,dropcacheonclose=false,moveonenospc=true
        add_pool /mnt/storage d pfrd $full
        add_pool /mnt/media m mfs $full
        add_pool /mnt/flash f epmfs $full
        add_pool /mnt/scratch x
    else
        add_pool /mnt/storage d
        add_pool /mnt/media m
        add_pool /mnt/flash f
        add_pool /mnt/scratch x
    fi
fi

# Whatever was set up from the UI in a previous run.
mount -a 2>&1 | sed 's/^/[lab] mount: /'

# SMART profiles, created once and then yours to edit (see `lab smart`). The kind of a disk decides
# the format of its SMART report and what lsblk says of it: kind|format|bus|removable, then its models
# as model|family|rpm|power-on hours.
kinds=("hdd|ata|sata|0" "smr|ata|sata|0" "ssd|ata|sata|0" "nvme|nvme|nvme|0" "sas|scsi|sas|0" "usb|ata|usb|1")
models_hdd=("WDC WD40EFPX-68C6CN0|Western Digital Red Plus|5400|5400" "ST4000VN006-3CW104|Seagate IronWolf|5400|21500" \
            "TOSHIBA HDWG440|Toshiba N300|7200|38900" "HGST HUS726T4TALA6L4|HGST Ultrastar 7K6|7200|46200" \
            "WDC WD80EFZZ-68BTXN0|Western Digital Red Plus|5640|12800")
models_smr=("ST8000AS0002-1NA17Z|Seagate Archive HDD (SMR)|5980|31200" "WDC WD40EFAX-68JH4N1|Western Digital Red (SMR)|5400|17700")
models_ssd=("Samsung SSD 870 EVO 1TB|Samsung based SSDs|0|9100" "CT1000MX500SSD1|Crucial/Micron Client SSDs|0|14300")
models_nvme=("Samsung SSD 980 PRO 1TB||0|6200" "WD_BLACK SN850X 1000GB||0|3100" "CT1000P3SSD8||0|1900")
models_sas=("HGST HUH721212AL5200||7200|28700" "SEAGATE ST12000NM0027||7200|33400")
models_usb=("WDC WD20SPZX-22UA7T0|Western Digital Elements (USB)|5400|2600")
default_kinds=(hdd hdd hdd ssd hdd hdd)
k=0
for d in "${disks[@]}"; do
    if [ ! -f "$LAB/smart/$d.env" ]; then
        kind=$(lookup "$TYPES" "$d")
        if [ -z "$kind" ]; then
            case $d in f*|g*) kind=nvme ;; u*) kind=usb ;; x*) kind=ssd ;; *) kind=${default_kinds[$((k % ${#default_kinds[@]}))]} ;; esac
        fi
        spec=; for e in "${kinds[@]}"; do [ "${e%%|*}" = "$kind" ] && spec=$e; done
        [ -n "$spec" ] || { log "unknown kind '$kind' of the disk $d, using hdd"; kind=hdd; spec=${kinds[0]}; }
        IFS='|' read -r _ format tran removable <<< "$spec"
        declare -n list="models_$kind"
        IFS='|' read -r model family rpm hours <<< "${list[$((k % ${#list[@]}))]}"
        unset -n list
        case $d in s*) hours=$((k * 3)) ;; esac   # spares are new
        {
            echo "TYPE=$kind"; echo "KIND=$format"; echo "TRAN=$tran"; echo "REMOVABLE=$removable"
            echo "MODEL=\"$model\""; echo "FAMILY=\"$family\""
            echo "SERIAL=\"LAB$(printf '%04d' $((1000 + k * 37)))${d^^}\""
            echo "RPM=$rpm"; echo "TEMP=$((31 + (k * 3) % 9))"; echo "POWER_ON_HOURS=$hours"
            echo "START_STOP=$((40 + k * 13))"; echo "POWER_CYCLE=$((38 + k * 11))"; echo "LOAD_CYCLE=$((900 + k * 410))"
            echo "REALLOCATED=0"; echo "PENDING=0"; echo "UNCORRECTABLE=0"; echo "CRC_ERRORS=0"; echo "REPORTED_UNCORRECT=0"
            [ "$format" = ata ] && [ "$rpm" = 0 ] && echo "WEAR_LEVEL=094"
            [ "$format" = nvme ] && { echo "WEAR_USED=$((1 + k % 7))"; echo "SPARE=100"; echo "MEDIA_ERRORS=0"; echo "ERROR_LOG=0"; echo "UNSAFE_SHUTDOWNS=$((2 + k % 5))"; }
            [ "$format" = scsi ] && echo "NON_MEDIUM_ERRORS=0"
            echo "FAILING=0"
        } > "$LAB/smart/$d.env"
        # One ageing disk, so the health pages have something to say.
        [ "$d" = d3 ] && sed -i 's/^REALLOCATED=0/REALLOCATED=8/; s/^TEMP=.*/TEMP=44/' "$LAB/smart/$d.env"
    fi
    k=$((k + 1))
done
has() { local d; for d in "${disks[@]}"; do [ "$d" = "$1" ] && return 0; done; return 1; }
kind_of() { ( KIND=ata; TRAN=sata; . "$LAB/smart/$1.env" 2>/dev/null; echo "$KIND/$TRAN" ) }

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
        if [ "$SHOWCASE" = 1 ]; then
            echo
            echo "# Disks that are not of the array, watched by 'smart' and 'probe' all the same"
            for d in "${disks[@]}"; do case $d in x*|u*) echo "extra $d /mnt/lab/$d" ;; esac; done
            echo
            echo "# Files that are not protected: hidden ones, and what can be downloaded again"
            echo "nohidden"
            echo "exclude *.unrecoverable"
            echo "exclude *.part"
            echo "exclude /Downloads/incomplete/"
            echo "exclude Thumbs.db"
            echo
            echo "# The defaults, written down: changing them later means building the parity again"
            echo "blocksize 256"
            echo "hashsize 16"
            echo
            echo "# Above this temperature the command stops, spins the disks down and waits"
            echo "temp_limit 55"
            echo "temp_sleep 3"
            echo
            echo "# Folder of symbolic links to every file of the array, made by 'snapraid pool'"
            echo "pool $LAB/links"
            echo
            echo "# How to ask SMART data to the disks behind a controller or a USB bridge"
            for d in "${disks[@]}"; do
                case $d in d*|x*|u*) n=$d ;; p*) n=${PARITY_NAMES[$((${d#p} - 1))]} ;; *) continue ;; esac
                case $(kind_of "$d") in scsi/*) echo "smartctl $n -d scsi %s" ;; */usb) echo "smartctl $n -d sat %s" ;; esac
            done
            echo
            echo "# Attributes that do not count in the failure probability of a disk"
            echo "smartignore * Spin_Up_Time"
            has d3 && echo "smartignore d3 Reallocated_Event_Count"
        fi
    } > $LAB/etc/snapraid.conf
    [ "$SHOWCASE" = 1 ] && mkdir -p $LAB/links
fi
# What the showcase adds to the options of every array: a hook around every task, and the three
# notifications. In the lab they end in files, see `lab inbox` and `lab hooks`.
showcase_options() {
    cat <<CONF
sync_prehash = 1
sync_prevent_truncations = 1
hook_script = /usr/local/share/lab/hook.sh
notify_start = /usr/local/share/lab/notify.sh start "%s" %l %h
notify_result = /usr/local/share/lab/notify.sh result "%s" %l %h %c
notify_heartbeat = /usr/local/share/lab/notify.sh heartbeat
CONF
}
# The second array: its SnapRAID configuration, and its own daemon options in the arrays directory.
has_media=0; for d in "${disks[@]}"; do [ "$d" = m1 ] && has_media=1; done
if [ "$PRESET" = ready ] && [ $has_media = 1 ] && [ ! -f $LAB/etc/snapraid/media.conf ]; then
    mkdir -p $LAB/etc/snapraid $LAB/etc/snapraidd.d
    {
        echo "# SnapRAID lab, second array"
        if has q2; then
            echo "# one parity level split over two disks: when the first file cannot grow, the second is used"
            echo "parity /mnt/lab/q1/snapraid.parity,/mnt/lab/q2/snapraid.parity"
        else
            echo "parity /mnt/lab/q1/snapraid.parity"
        fi
        echo "content $LAB/etc/media.content"
        echo "content /mnt/lab/m1/snapraid.content"
        for d in "${disks[@]}"; do case $d in m*) echo "data $d /mnt/lab/$d" ;; esac; done
        echo "exclude *.tmp"; echo "exclude /lost+found/"
        echo "autosave 1"
    } > $LAB/etc/snapraid/media.conf
    cat > $LAB/etc/snapraidd.d/media.conf <<CONF
# SnapRAID Daemon lab, options of the array 'media' (the ones of the machine are in snapraidd.conf)
engine_conf = $LAB/etc/snapraid/media.conf
maintenance_schedule = 03:00
sync_threshold_deletes = 50
sync_threshold_updates = 100
scrub_percentage = 12
scrub_older_than = 10
touch_zero_subseconds = 1
probe_interval_minutes = 1
spindown_idle_minutes = 15
notify_result_level = warning
notify_differences = 1
CONF
    if [ "$SHOWCASE" = 1 ]; then
        # a schedule of two days, and the parity disks left spinning longer than the data disks
        sed -i 's|^maintenance_schedule = .*|maintenance_schedule = Wed 03:00, Sat 03:00|; s|^spindown_idle_minutes = .*|spindown_idle_minutes = 15, 45|' $LAB/etc/snapraidd.d/media.conf
        showcase_options >> $LAB/etc/snapraidd.d/media.conf
    fi
fi
# The third array, on flash disks.
if [ "$PRESET" = ready ] && has f1 && [ ! -f $LAB/etc/snapraid/flash.conf ]; then
    mkdir -p $LAB/etc/snapraid $LAB/etc/snapraidd.d
    snap=0; for d in "${disks[@]}"; do case $d in f*) [ "$(fs_of "$d")" = btrfs ] && snap=1 ;; esac; done
    {
        echo "# SnapRAID lab, third array: flash disks"
        echo "parity /mnt/lab/g1/snapraid.parity"
        echo "content $LAB/etc/flash.content"
        echo "content /mnt/lab/f1/snapraid.content"
        for d in "${disks[@]}"; do case $d in f*) echo "data $d /mnt/lab/$d" ;; esac; done
        echo "exclude *.tmp"; echo "exclude /lost+found/"
        echo "autosave 1"
        if [ $snap = 1 ]; then
            echo "# a sync reads the Btrfs data disks from a snapshot taken when it starts: what is"
            echo "# changed or deleted afterwards stays recoverable until the next sync"
            echo "snapshot"
        fi
    } > $LAB/etc/snapraid/flash.conf
    cat > $LAB/etc/snapraidd.d/flash.conf <<CONF
# SnapRAID Daemon lab, options of the array 'flash' (the ones of the machine are in snapraidd.conf)
engine_conf = $LAB/etc/snapraid/flash.conf
# twice a day: these disks change often
maintenance_schedule = 01:00, 13:00
# a sync is never stopped by the number of changes
sync_threshold_deletes = 0
sync_threshold_updates = 0
# everything is verified at every run
scrub_percentage = 100
scrub_older_than = 0
touch_zero_subseconds = 1
probe_interval_minutes = 1
# flash disks are not spun down
spindown_idle_minutes = 0
notify_result_level = warning
notify_differences = 1
CONF
    [ "$SHOWCASE" = 1 ] && showcase_options >> $LAB/etc/snapraidd.d/flash.conf
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
    if [ "$SHOWCASE" = 1 ]; then
        # every result is notified, not only the bad ones; two schedules; parity disks spun down later
        sed -i 's|^notify_result_level = .*|notify_result_level = info|; s|^maintenance_schedule = .*|maintenance_schedule = 02:00, Sun 05:00|; s|^spindown_idle_minutes = .*|spindown_idle_minutes = 15, 30|' $LAB/etc/snapraidd.conf
        {
            showcase_options
            echo "# arrays that share no disk run together"
            echo "array_parallel = 1"
            echo "# the logs of the commands are kept compressed"
            echo "sys_log_compression = 1"
            echo "# changes of these attributes are not reported"
            echo "sys_smartignore = * Spin_Up_Time Raw_Read_Error_Rate"
        } >> $LAB/etc/snapraidd.conf
    fi
fi
# The login, when asked: without it the lab is open to the private addresses of net_acl.
sed -i '/^net_auth_credential/d' $LAB/etc/snapraidd.conf
if [ -n "$AUTH" ]; then
    cred=$(snapraidd -g "$AUTH" 2>/dev/null | grep -oE '[^ =]+:\$argon2id\$.*' | head -1)
    if [ -n "$cred" ]; then
        sed -i "s|^net_web_root = .*|net_auth_credential = $cred\n&|" $LAB/etc/snapraidd.conf
        log "login enabled for the user '${AUTH%%:*}'"
    else
        log "WARNING: cannot make the credential of LAB_AUTH, the login stays off"
    fi
fi
grep -q '^net_acl' $LAB/etc/snapraidd.conf || sed -i 's|^net_web_root = .*|net_acl = +127.0.0.1,+10.0.0.0/8,+172.16.0.0/12,+192.168.0.0/16\n&|' $LAB/etc/snapraidd.conf
grep -q '^net_storage_admin' $LAB/etc/snapraidd.conf || sed -i 's|^net_web_root = .*|net_storage_admin = 1\n&|' $LAB/etc/snapraidd.conf
sed -i "s|^net_web_root = .*|net_web_root = /ui/$UI|" $LAB/etc/snapraidd.conf

# Sample content on new data disks, a first sync, then some changes left pending.
seeded=0; seeded_media=0; seeded_flash=0
for d in "${fresh_disks[@]}"; do
    case $d in
    d*) lab seed "$d"; seeded=1 ;;
    m*) lab seed "$d"; seeded_media=1 ;;
    f*) lab seed "$d"; seeded_flash=1 ;;
    x*) lab fill "/mnt/lab/$d" 40 >/dev/null ;;
    u*) lab fill "/mnt/lab/$d" 20 >/dev/null ;;
    esac
done
if [ $seeded_flash = 1 ] && [ ! -f $LAB/etc/flash.content ] && [ -f $LAB/etc/snapraid/flash.conf ]; then
    log "first sync of the third array"
    snapraid -c $LAB/etc/snapraid/flash.conf -q sync >/dev/null 2>$LAB/log/first-sync-flash.err || log "first sync of the third array failed, see $LAB/log/first-sync-flash.err"
fi
if [ $seeded_media = 1 ] && [ ! -f $LAB/etc/media.content ] && [ -f $LAB/etc/snapraid/media.conf ]; then
    log "first sync of the second array"
    snapraid -c $LAB/etc/snapraid/media.conf -q sync >/dev/null 2>$LAB/log/first-sync-media.err || log "first sync of the second array failed, see $LAB/log/first-sync-media.err"
fi
if [ $seeded = 1 ] && [ ! -f $LAB/etc/snapraid.content ]; then
    log "first sync of the new array"
    snapraid -c $LAB/etc/snapraid.conf -q sync >/dev/null 2>$LAB/log/first-sync.err || log "first sync failed, see $LAB/log/first-sync.err"
    grep -q '^pool ' $LAB/etc/snapraid.conf && snapraid -c $LAB/etc/snapraid.conf -q pool >/dev/null 2>&1
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
