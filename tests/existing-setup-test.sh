#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# End to end test of the installation on a machine where SnapRAID is already in use from the
# command line, without the daemon: the engine of the distribution, a snapraid.conf, an
# /etc/fstab and a mergerfs pool written by hand, a nightly cron job.
#
# It checks that the installer and the daemon are a drop in addition: nothing of the existing
# setup is changed, 'snapraid' keeps working from the shell next to the daemon, and removing
# the package leaves everything as it was.
#
# DESTRUCTIVE: it installs and removes packages and rewrites /etc/fstab and /etc/snapraid.conf
# of the container. It runs only in a container started for it, and builds no lab:
#
#     docker compose -f docker-compose.existing.yml up --build --abort-on-container-exit --exit-code-from tests
#     docker compose -f docker-compose.existing.yml down -v
#
# The packages are in $LAB_PKG, put there by the Dockerfile when built with LAB_PACKAGES=1:
#   snapraid-old.deb      the engine of the distribution (SnapRAID 12): its content file is in
#                         the format that SnapRAID 15 refuses
#   snapraid-migrate.deb  SnapRAID 14.10, that converts it
#   snapraid-new.deb      SnapRAID 15
#   daemon.deb            the daemon with the Storage page, built from the checkout
#   installer.sh          its installer
# The installer installs with apt: the container needs the network for the dependencies.

[ "${LAB_EXISTING:-0}" = 1 ] || { echo "refusing to run: this container was not started by docker-compose.existing.yml"; exit 99; }

PKG=${LAB_PKG:-/usr/local/share/lab/pkg}
for f in snapraid-old.deb snapraid-migrate.deb snapraid-new.deb daemon.deb installer.sh; do
    [ -f "$PKG/$f" ] || { echo "refusing to run: $PKG/$f is missing, build the image with LAB_PACKAGES=1"; exit 99; }
done

W=/var/lab-existing
IMG=$W/img
U=http://127.0.0.1:7627/snapraid
AUTH="admin:test"
LOCK=/var/snapraid/snapraid.content.lock
DAEMON=/usr/bin/snapraidd
PASS=0; FAILS=0
export DEBIAN_FRONTEND=noninteractive

ok()   { PASS=$((PASS + 1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; }
section() { echo; echo "== $1"; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "failed: $*"; fi; }
not()  { ! "$@"; }
api()  { curl -s -m 120 -u "$AUTH" "$U$1"; }
post() { curl -s -m 120 -u "$AUTH" -X "${3:-POST}" -H 'Content-Type: application/json' --data-binary "$2" "$U$1"; }
format_of() { head -c 8 "$1" | tr -d '\0'; }
tasks_wait() {
    sleep 2
    for _ in $(seq 1 600); do
        [ "$(api /v1/tasks | jq '(.active | length) + (.pending | length)')" = 0 ] && return 0
        sleep 1
    done
    return 1
}
# the result of the most recent task of a command: "status exit_code"
last_task() { api /v1/tasks | jq -r --arg c "$1" '[.history[] | select(.command == $c)][0] | "\(.status) \(.exit_code)"'; }

# ---------------------------------------------------------------------------
# the machine
# ---------------------------------------------------------------------------

# Everything the owner of the array cares about, to compare before and after.
#   conf   the files written by hand
#   array  content and parity files
#   data   the files on the data disks, by content
#   tree   the same with sizes, times and owners
#   mounts what is mounted, and the options of the pool
snap() {
    local o=$W/snap/$1; rm -rf "$o"; mkdir -p "$o"
    for f in /etc/snapraid.conf /etc/snapraid.conf.bak /etc/fstab /etc/cron.d/snapraid /usr/local/bin/snapraid-nightly.sh; do
        sha256sum $f; stat -c '%a %U:%G %n' $f
    done > "$o/conf" 2>&1
    sha256sum /mnt/parity1/snapraid.parity /mnt/parity2/snapraid.2-parity > "$o/parity" 2>&1
    sha256sum /var/snapraid/snapraid.content /mnt/disk1/.snapraid.content /mnt/disk2/.snapraid.content > "$o/content" 2>&1
    ( cd /mnt && find disk? -xdev -type f ! -name '.snapraid.content*' -print0 | sort -z | xargs -0 sha256sum ) > "$o/data"
    ( cd /mnt && find disk? -xdev -mindepth 1 ! -name '.snapraid.content*' -printf '%p %s %T@ %m %u\n' | sort ) > "$o/tree"
    {
        findmnt -rn -o TARGET,SOURCE,FSTYPE | grep -E '^/mnt/(disk|parity|storage)' | sort
        lsattr -d /mnt/disk? /mnt/parity? /mnt/storage 2>/dev/null
        for k in srcmounts category.create minfreespace moveonenospc; do
            getfattr -n user.mergerfs.$k --only-values /mnt/storage/.mergerfs 2>/dev/null; echo
        done
    } > "$o/mounts"
}
# same NAME... : the listed parts are identical in the two snapshots
same() {
    local a=$W/snap/$1 b=$W/snap/$2 p; shift 2
    for p in "$@"; do cmp -s "$a/$p" "$b/$p" || { diff "$a/$p" "$b/$p" | head -5; return 1; }; done
}

stop_daemon() {
    pkill -x snapraidd 2>/dev/null
    for _ in $(seq 1 50); do pgrep -x snapraidd >/dev/null || break; sleep 0.2; done
}

teardown() {
    stop_daemon
    umount /mnt/storage 2>/dev/null
    for m in /mnt/disk? /mnt/parity?; do umount "$m" 2>/dev/null; done
    for f in "$IMG"/*.img; do
        [ -f "$f" ] && for l in $(losetup -j "$f" -O NAME -n); do losetup -d "$l" 2>/dev/null; done
    done
    apt-get purge -y -q snapraid snapraid-daemon-storage snapraid-daemon >/dev/null 2>&1
    rm -rf "$IMG" /etc/snapraid.conf* /etc/snapraidd.conf* /etc/snapraidd.d /etc/snapraid /var/snapraid /var/log/snapraid \
        /etc/cron.d/snapraid /usr/local/bin/snapraid /usr/local/bin/snapraid-nightly.sh /usr/local/etc/snapraid.conf \
        /etc/fstab.snapraidd.bak /mnt/disk? /mnt/parity? /mnt/storage
    : > /etc/fstab
}

# A disk with a partition table, like a real one: SnapRAID resolves the filesystem on
# loopNp1 back to the device loopN, and the fake smartctl of the lab answers for it.
disk() { # name sizeMB fs -> prints the partition
    local img=$IMG/$1.img loop base part
    truncate -s "${2}M" "$img"
    echo 'type=83' | sfdisk -q "$img"
    loop=$(losetup -fP --show "$img"); base=${loop##*/}; part=${loop}p1
    for _ in $(seq 1 20); do [ -e "/sys/block/$base/${base}p1/dev" ] && break; partx -a "$loop" 2>/dev/null; sleep 0.1; done
    [ -b "$part" ] || mknod "$part" b $(tr ':' ' ' < "/sys/block/$base/${base}p1/dev")
    case $3 in ext4) mkfs.ext4 -q -L "$1" "$part" ;; xfs) mkfs.xfs -q -L "$1" "$part" ;; esac
    mkdir -p /run/lab/map "${LAB_DIR:-/lab}/smart"
    echo "$1" > "/run/lab/map/$base"; echo "KIND=ata" > "${LAB_DIR:-/lab}/smart/$1.env"
    echo "$part"
}

# The machine of somebody using SnapRAID from the shell for years.
# $1: where the engine is: "package" (the one of the distribution) or "sources" (/usr/local)
machine() {
    local d1 d2 d3 d4 p1 p2 d n conf=/etc/snapraid.conf
    mkdir -p "$IMG" "$W/snap"
    if [ "$1" = sources ]; then
        mkdir -p /usr/local/etc && cp "$OLDBIN" /usr/local/bin/snapraid
        conf=/usr/local/etc/snapraid.conf
    else
        apt-get install -y -q --allow-downgrades "$PKG/snapraid-old.deb" >/dev/null 2>&1 || return 1
    fi
    hash -r
    d1=$(disk disk1 300 ext4); d2=$(disk disk2 400 xfs); d3=$(disk disk3 300 ext4); d4=$(disk disk4 350 ext4)
    p1=$(disk parity1 500 ext4); p2=$(disk parity2 500 xfs)
    mkdir -p /mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/disk4 /mnt/parity1 /mnt/parity2 /mnt/storage /var/snapraid
    uuid() { blkid -s UUID -o value "$1"; }
    # every way of naming a disk, comments, tabs and a pool given with a pattern
    cat > /etc/fstab <<EOF
# /etc/fstab: static file system information.
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
# -- my data disks (added 2019, disk4 added 2022) --
UUID=$(uuid "$d1")	/mnt/disk1	ext4	defaults,noatime	0	2
UUID=$(uuid "$d2") /mnt/disk2 xfs defaults,noatime 0 2
LABEL=disk3  /mnt/disk3  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10  0  2
$d4 /mnt/disk4 ext4 defaults 0 2
# parity
UUID=$(uuid "$p1") /mnt/parity1 ext4 defaults,noatime 0 2
UUID=$(uuid "$p2") /mnt/parity2 xfs defaults,noatime 0 2

# mergerfs pool, do not touch!
/mnt/disk*  /mnt/storage  fuse.mergerfs  defaults,allow_other,use_ino,cache.files=off,dropcacheonclose=true,category.create=mfs,moveonenospc=true,minfreespace=20M,fsname=mergerfs  0  0
EOF
    mount -a || return 1
    # the old 'disk' keyword, three content files, comments everywhere
    cat > $conf <<'EOF'
# My SnapRAID config - edited by hand since 2019
# DO NOT LOSE THIS FILE

# Parity
parity /mnt/parity1/snapraid.parity
2-parity /mnt/parity2/snapraid.2-parity

# Content: three copies
content /var/snapraid/snapraid.content
content /mnt/disk1/.snapraid.content
content /mnt/disk2/.snapraid.content

# Data disks. NOTE: d3 was replaced in 2023
data d1 /mnt/disk1/
data d2 /mnt/disk2/
disk d3 /mnt/disk3/
data d4 /mnt/disk4/

# Excludes
exclude *.unrecoverable
exclude /tmp/
exclude /lost+found/
exclude .Trash-*/
exclude *.!sync
exclude /downloads/incomplete/

nohidden
blocksize 256
autosave 5
EOF
    # a backup of the owner, with the name the daemon used for its own until 2.2.s4
    [ "$1" = sources ] || echo "# my own backup, 2021" > /etc/snapraid.conf.bak
    for d in 1 2 3 4; do
        mkdir -p /mnt/disk$d/media/show$d /mnt/disk$d/photos /mnt/disk$d/downloads/incomplete "/mnt/disk$d/docs with space"
        for n in $(seq 1 30); do head -c $((RANDOM * 8 + 1000)) /dev/urandom > /mnt/disk$d/media/show$d/ep$n.mkv; done
        for n in $(seq 1 20); do head -c $((RANDOM + 10)) /dev/urandom > /mnt/disk$d/photos/img$n.jpg; done
        echo part > /mnt/disk$d/downloads/incomplete/x.part
        echo "ünïcödé" > "/mnt/disk$d/docs with space/fïle ñame.txt"
        echo hidden > /mnt/disk$d/.hiddenfile
        # whole second timestamps, as left by old copy tools
        touch -d "2021-03-04 05:06:07" /mnt/disk$d/photos/img1.jpg /mnt/disk$d/photos/img2.jpg
    done
    cat > /etc/cron.d/snapraid <<'EOF'
# nightly snapraid, by hand
30 2 * * * root /usr/local/bin/snapraid-nightly.sh
EOF
    printf '#!/bin/sh\nsnapraid sync && snapraid scrub -p 5 -o 10\n' > /usr/local/bin/snapraid-nightly.sh
    chmod +x /usr/local/bin/snapraid-nightly.sh
    snapraid -c $conf sync >/dev/null 2>&1 && snapraid -c $conf scrub -p 30 >/dev/null 2>&1
}

# run the installer of the checkout with the packages of the image; the output is in $W/install.log
install() {
    env SNAPRAIDD_PASSWORD=test SNAPRAIDD_DEB="$PKG/daemon.deb" SNAPRAID_DEB="$PKG/snapraid-new.deb" \
        SNAPRAID_MIGRATE_DEB="$PKG/snapraid-migrate.deb" "$@" sh "$PKG/installer.sh" > "$W/install.log" 2>&1
}
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }
engine_version() { dpkg-query -W -f='${Version}' snapraid 2>/dev/null; }

start_daemon() {
    $DAEMON || return 1
    for _ in $(seq 1 60); do [ "$(api /v1/array | jq -r '.health // empty' 2>/dev/null)" = passed ] && break; sleep 1; done
    tasks_wait
}

mkdir -p "$W"
teardown
# the engines out of their packages, to run them without installing them
mkdir -p "$W/old" "$W/new"
dpkg-deb -x "$PKG/snapraid-old.deb" "$W/old"; OLDBIN=$W/old/usr/bin/snapraid
dpkg-deb -x "$PKG/snapraid-new.deb" "$W/new"; NEWBIN=$W/new/usr/bin/snapraid

# ---------------------------------------------------------------------------
section "the machine before: SnapRAID from the shell only"
# ---------------------------------------------------------------------------
check "an array made with the engine of the distribution is synced" machine package
OLD=$(engine_version)
check "its content file is in the format of SnapRAID 13 and older" test "$(format_of /var/snapraid/snapraid.content)" = SNAPCNT2
check "the pool written by hand is up" findmnt -n -t fuse.mergerfs /mnt/storage
NEWOUT=$("$NEWBIN" status 2>&1)
if echo "$NEWOUT" | grep -q "Legacy content format is no longer supported"; then
    ok "SnapRAID 15 refuses that content file: a plain upgrade of the engine would stop the array"
else
    fail "SnapRAID 15 refuses that content file" "$(echo "$NEWOUT" | tail -2)"
fi
snap before

# ---------------------------------------------------------------------------
section "the installer stops, changing nothing, when going on is not safe"
# ---------------------------------------------------------------------------
echo new > /mnt/disk1/photos/new.jpg; mv /mnt/disk2/photos/img9.jpg "$W/img9.jpg"
snap pending
install; RC=$?
check "changes not synced: it stops" test $RC = 1
check "it shows the differences" grep -q "1 added" "$W/install.log"
check "it tells how to go on, with a sync asked for or made by hand" grep -q "SNAPRAID_SYNC=1" "$W/install.log"
snap pending2
check "nothing was changed" same pending pending2 conf parity content data tree mounts
check "nothing was installed" not installed snapraid-daemon-storage
check "the engine is still the old one" test "$(engine_version)" = "$OLD"
rm /mnt/disk1/photos/new.jpg; mv "$W/img9.jpg" /mnt/disk2/photos/img9.jpg

( flock -x "$LOCK" sleep 25 ) &
sleep 1
install; RC=$?
wait
check "a sync of the owner running: it stops" test $RC = 1
check "it says that SnapRAID is in use" grep -q "already in use" "$W/install.log"
snap locked
check "nothing was changed" same before locked conf parity content data mounts
check "nothing was installed" not installed snapraid-daemon-storage

umount /mnt/storage; umount /mnt/disk3
install SNAPRAID_SYNC=1; RC=$?
mount /mnt/disk3; mount /mnt/storage
check "a disk not mounted, even with a sync asked for: it stops" test $RC = 1
check "SnapRAID refused to sync the empty folder" grep -q "force-empty" "$W/install.log"
snap unmounted
check "nothing was changed" same before unmounted conf parity content data mounts
check "nothing was installed" not installed snapraid-daemon-storage

# ---------------------------------------------------------------------------
section "installation on the synced array"
# ---------------------------------------------------------------------------
snap ready
install; RC=$?
check "the installer completes" test $RC = 0
[ $RC = 0 ] || tail -15 "$W/install.log"
check "the content files were converted before the upgrade" grep -q "Content files converted" "$W/install.log"
check "without a sync of the parity" grep -q "the parity is not touched" "$W/install.log"
check "all the three content files are in the new format" test "$(format_of /var/snapraid/snapraid.content)$(format_of /mnt/disk1/.snapraid.content)$(format_of /mnt/disk2/.snapraid.content)" = SNAPCNT3SNAPCNT3SNAPCNT3
check "the engine is SnapRAID 15" dpkg --compare-versions "$(engine_version)" ge 15.0
check "the upgrade of the engine is told" grep -q "engine was upgraded from $OLD" "$W/install.log"
check "the daemon is installed" installed snapraid-daemon-storage
snap installed
check "snapraid.conf, fstab, the cron job and the own backup are as they were" same before installed conf
check "the parity files are as they were" same before installed parity
check "the data is as it was, with its timestamps" same ready installed data tree
check "the disks and the pool are mounted as they were" same before installed mounts
check "'snapraid status' of the new engine finds no error" sh -c "snapraid status | grep -q 'No error detected'"
check "'snapraid diff' finds nothing to sync" snapraid diff
check "the old engine still reads the array: going back is possible" "$OLDBIN" status
check "the daemon has no maintenance schedule" grep -qx "maintenance_schedule =" /etc/snapraidd.conf
check "the daemon does not spin down the disks" grep -qx "spindown_idle_minutes = 0" /etc/snapraidd.conf
check "the installer says that the daemon only watches" grep -q "only watches the array" "$W/install.log"
check "the cron job of the owner is found and named" grep -q "/etc/cron.d/snapraid" "$W/install.log"
check "the web UI is protected by the password" grep -q "^net_auth_credential = admin:" /etc/snapraidd.conf

# ---------------------------------------------------------------------------
section "the daemon next to the array"
# ---------------------------------------------------------------------------
check "the daemon starts" start_daemon
ARRAY=$(api /v1/array)
check "it takes the array as it is: 4 data disks, 2 parity" test "$(echo "$ARRAY" | jq -r '"\(.data_disks_count) \(.parity_disks_count)"')" = "4 2"
check "the array is healthy" test "$(echo "$ARRAY" | jq -r .health)" = passed
check "it read the content file" test "$(echo "$ARRAY" | jq -r .files_count)" -gt 100
INV=$(api /v1/storage)
check "the pool written by hand is shown with its four disks" test "$(echo "$INV" | jq -r '.pools[] | select(.mountpoint == "/mnt/storage") | .branches | length')" = 4
check "every disk of the pool is known as protected data" test "$(echo "$INV" | jq -r '[.pools[0].branches[] | select(.protected and .role == "data")] | length')" = 4
check "the configuration is shown as written, comments included" test "$(echo "$INV" | jq -r .engine_conf.text)" = "$(cat /etc/snapraid.conf)"
check "no maintenance is scheduled" test "$(api /v2/config | jq -r .maintenance_schedule)" = ""
sleep 20
snap watching
check "the daemon running changes nothing by itself" same installed watching conf parity content data tree mounts

# ---------------------------------------------------------------------------
section "'snapraid' from the shell while the daemon runs"
# ---------------------------------------------------------------------------
echo n1 > /mnt/disk3/photos/n1.jpg; rm /mnt/disk4/photos/img5.jpg
check "diff sees the changes" test "$(snapraid diff >/dev/null 2>&1; echo $?)" = 2
check "sync" snapraid sync
SUM=$(sha256sum < /mnt/disk1/media/show1/ep3.mkv); rm /mnt/disk1/media/show1/ep3.mkv
check "fix brings a deleted file back" snapraid fix -m
check "with its content" test "$(sha256sum < /mnt/disk1/media/show1/ep3.mkv)" = "$SUM"
check "scrub" snapraid scrub -p 100 -o 0
check "check" snapraid check -a
check "status finds no error" sh -c "snapraid status | grep -q 'No error detected'"
# the daemon looks at the content file at every periodic probe
post /v2/config '{"probe_interval_minutes":1}' PATCH >/dev/null
BEFORE=$(api /v1/array | jq -r .files_count)
for n in 1 2 3; do echo n > /mnt/disk3/photos/more$n.jpg; done
snapraid sync >/dev/null 2>&1
for _ in $(seq 1 150); do [ "$(api /v1/array | jq -r .files_count)" = $((BEFORE + 3)) ] && break; sleep 1; done
check "the daemon notices a sync made from the shell: it counts the three new files" test "$(api /v1/array | jq -r .files_count)" = $((BEFORE + 3))
check "and stays healthy" test "$(api /v1/array | jq -r .health)" = passed
READS=$(api /v1/tasks | jq '[.history[] | select(.command == "read")] | length')
sleep 130
check "it reads the content file once for a change, not at every probe" test "$(api /v1/tasks | jq '[.history[] | select(.command == "read")] | length')" = "$READS"

echo "exclude *.tmp" >> /etc/snapraid.conf; echo t > /mnt/disk1/x.tmp
check "a line added by hand to snapraid.conf is shown by the daemon" sh -c "curl -s -u $AUTH $U/v1/storage | jq -r .engine_conf.text | grep -qx 'exclude \*.tmp'"
post /v1/schedule '{"tasks":[{"command":"diff"}]}' >/dev/null; tasks_wait
check "and used by its next command" test "$(api /v1/array | jq -r .diff_added)" = 0
sed -i '$d' /etc/snapraid.conf; rm /mnt/disk1/x.tmp

# ---------------------------------------------------------------------------
section "a command of the daemon while 'snapraid' runs in the shell"
# ---------------------------------------------------------------------------
echo n3 > /mnt/disk2/photos/n3.jpg
snap clash
( flock -x "$LOCK" sleep 20 ) &
sleep 1
post /v1/maintenance '{}' >/dev/null; tasks_wait
wait
check "the sync of the daemon does not run" test "$(last_task sync)" = "canceled null"
check "the reason is told: SnapRAID is in use" sh -c "curl -s -u $AUTH $U/v1/tasks | jq -r '.history[0:6][].messages[]?.text' | grep -q 'already in use'"
check "the array stays healthy" test "$(api /v1/array | jq -r .health)" = passed
snap clash2
check "nothing was changed" same clash clash2 conf parity content data tree mounts

# ---------------------------------------------------------------------------
section "the maintenance of the daemon, when asked"
# ---------------------------------------------------------------------------
post /v1/maintenance '{}' >/dev/null; tasks_wait
check "sync completes" test "$(last_task sync)" = "terminated 0"
check "scrub completes" test "$(last_task scrub)" = "terminated 0"
check "the shell agrees: nothing left to sync" snapraid diff
READS=$(api /v1/tasks | jq '[.history[] | select(.command == "read")] | length')
sleep 70
check "its own sync is not taken for one made from the shell" test "$(api /v1/tasks | jq '[.history[] | select(.command == "read")] | length')" = "$READS"
snap maintained
check "the data is not changed, nor the files written by hand" same clash maintained conf data mounts

# ---------------------------------------------------------------------------
section "changes made from the web UI"
# ---------------------------------------------------------------------------
cp /etc/snapraid.conf "$W/conf.before"
jq -n --arg t "$(cat /etc/snapraid.conf)"$'\n' '{text: $t}' > "$W/put.json"
check "saving the configuration as it is" test "$(post /v1/storage/engine_conf @"$W/put.json" PUT | jq -r .success)" = true
check "leaves it identical" cmp -s "$W/conf.before" /etc/snapraid.conf
check "the previous one is kept as .snapraidd.bak" cmp -s "$W/conf.before" /etc/snapraid.conf.snapraidd.bak
check "the own .bak of the owner is not overwritten" test "$(cat /etc/snapraid.conf.bak)" = "# my own backup, 2021"

cp /etc/fstab "$W/fstab.before"
exec 9> /mnt/storage/photos/open.tmp; echo hello >&9
OPTS=$(api /v1/storage | jq -r '.pools[0].fstab_options' | sed 's/category.create=mfs/category.create=epmfs/')
check "changing the policy of the pool" test "$(post /v1/storage/pool "{\"mountpoint\":\"/mnt/storage\",\"branches\":\"/mnt/disk1:/mnt/disk2:/mnt/disk3:/mnt/disk4\",\"options\":\"$OPTS\",\"persist\":true}" | jq -r .success)" = true
check "a file open in the pool stays writable: the pool is not remounted" sh -c 'echo world >&9'
exec 9>&-
check "the file has both writes" test "$(tr '\n' ' ' < /mnt/storage/photos/open.tmp)" = "hello world "
rm -f /mnt/storage/photos/open.tmp
check "the pool has the new policy" test "$(getfattr -n user.mergerfs.category.create --only-values /mnt/storage/.mergerfs)" = epmfs
check "only the line of the pool changed in fstab" test "$(diff "$W/fstab.before" /etc/fstab | grep -c '^[<>]')" = 2
check "comments and the other lines are as written" test "$(grep -v ' /mnt/storage ' /etc/fstab)" = "$(grep -v ' /mnt/storage ' "$W/fstab.before")"
check "the previous fstab is kept as .snapraidd.bak" cmp -s "$W/fstab.before" /etc/fstab.snapraidd.bak

# ---------------------------------------------------------------------------
section "running the installer again, and removing the package"
# ---------------------------------------------------------------------------
stop_daemon
cp /etc/snapraidd.conf "$W/daemon.conf"
install; RC=$?
check "a second run completes" test $RC = 0
check "the configuration of the daemon is kept" cmp -s "$W/daemon.conf" /etc/snapraidd.conf
check "and it says so" grep -q "existing configuration in /etc/snapraidd.conf was kept" "$W/install.log"

snap remove
apt-get remove -y -q snapraid-daemon-storage >/dev/null 2>&1
check "the package is removed" not installed snapraid-daemon-storage
snap removed
check "the array, the files written by hand and the pool are as they were" same remove removed conf parity content data tree mounts
echo n4 > /mnt/disk1/photos/n4.jpg
check "'snapraid sync' works as before" snapraid sync
check "'snapraid status' finds no error" sh -c "snapraid status | grep -q 'No error detected'"

# ---------------------------------------------------------------------------
section "other machines"
# ---------------------------------------------------------------------------
teardown
check "a second machine like the first" machine package
echo new > /mnt/disk1/photos/new.jpg
install SNAPRAID_SYNC=1 SNAPRAIDD_AUTO=1; RC=$?
check "changes not synced, with SNAPRAID_SYNC=1: it syncs and installs" test $RC = 0
check "the array is synced" snapraid diff
check "with SNAPRAIDD_AUTO=1 the daemon keeps its nightly maintenance" grep -qx "maintenance_schedule = 02:00" /etc/snapraidd.conf
check "and its spin down" grep -qx "spindown_idle_minutes = 15" /etc/snapraidd.conf

teardown
check "an array made with an engine built from the sources is synced" machine sources
check "its configuration is in /usr/local/etc" test -f /usr/local/etc/snapraid.conf -a ! -e /etc/snapraid.conf
snap sources
install; RC=$?
check "an engine built from the sources in /usr/local: it stops" test $RC = 1
check "it names the program to remove" grep -q "rm /usr/local/bin/snapraid" "$W/install.log"
check "and the configuration to move" grep -q "mv /usr/local/etc/snapraid.conf /etc/snapraid.conf" "$W/install.log"
check "nothing was installed" not installed snapraid-daemon-storage
rm /usr/local/bin/snapraid; mv /usr/local/etc/snapraid.conf /etc/snapraid.conf; hash -r
install; RC=$?
check "after doing what it says, the installer completes" test $RC = 0
check "the content files were converted" grep -q "Content files converted" "$W/install.log"
snap sources2
check "the array is as it was" same sources sources2 parity data tree mounts
check "'snapraid status' finds no error" sh -c "snapraid status | grep -q 'No error detected'"

teardown
install; RC=$?
check "a machine with no array: the installer completes" test $RC = 0
check "the daemon has its usual schedule" grep -qx "maintenance_schedule = 02:00" /etc/snapraidd.conf
check "and nothing is said about an existing array" not grep -q "already in use" "$W/install.log"

teardown
echo
echo "passed: $PASS   failed: $FAILS"
exit $FAILS
