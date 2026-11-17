#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# End to end tests of the storage API of snapraidd, against the emulated disks of the lab.
#
# DESTRUCTIVE: it formats the lab disks. It runs only in a lab started with LAB_PRESET=blank:
#
#     docker compose -f docker-compose.test.yml up --build --abort-on-container-exit
#
# Every test prints "ok" or "FAIL" with the reason; the exit code is the number of failures.

U=http://127.0.0.1:7627/snapraid/v1
S=$U/storage
T=${LAB_TEST_DIR:-/mnt/t}
LAB=${LAB_DIR:-/lab}
PASS=0; FAILS=0; SKIP=0
CODE=; BODY=

[ "$(cat $LAB/etc/lab-preset 2>/dev/null)" = blank ] || { echo "refusing to run: this lab was not started with LAB_PRESET=blank"; exit 99; }
[ -z "$(ls -A $T 2>/dev/null)" ] || { echo "refusing to run: $T is not empty, start from a new lab (docker compose down -v)"; exit 99; }

ok()   { PASS=$((PASS + 1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; }
skip() { SKIP=$((SKIP + 1)); echo "skip  $1 ($2)"; }
section() { echo; echo "== $1"; }

# req METHOD URL [JSON]
req() {
    local out
    if [ $# -ge 3 ]; then
        out=$(curl -s -m 600 -w '\n%{http_code}' -X "$1" -H 'Content-Type: application/json' --data-binary "$3" "$2")
    else
        out=$(curl -s -m 600 -w '\n%{http_code}' -X "$1" "$2")
    fi
    CODE=${out##*$'\n'}; BODY=${out%$'\n'*}
}
msg() { echo "$BODY" | jq -r '.message // empty' 2>/dev/null; }

# expect NAME CODE [REGEX on the message]
expect() {
    if [ "$CODE" != "$2" ]; then fail "$1" "status $CODE instead of $2: $(msg)"; return 1; fi
    if [ -n "${3:-}" ] && ! msg | grep -qiE "$3"; then fail "$1" "message '$(msg)' does not match '$3'"; return 1; fi
    ok "$1"
}
check() { # check NAME COMMAND...
    local name=$1; shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "failed: $*"; fi
}
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then fail "$name" "unexpectedly true: $*"; else ok "$name"; fi; }

job_wait() { # -> JOB json
    for _ in $(seq 1 900); do
        JOB=$(curl -s $S/job | jq -c .job)
        [ "$(echo "$JOB" | jq -r .running)" = false ] && return 0
        sleep 1
    done
    return 1
}
job_ok()   { job_wait && [ "$(echo "$JOB" | jq -r .success)" = true ]; }
job_msg()  { echo "$JOB" | jq -r .message; }
tasks_wait() {
    sleep 2
    for _ in $(seq 1 900); do
        TASKS=$(curl -s "$U/tasks")
        [ "$(echo "$TASKS" | jq '(.active | length) + (.pending | length)')" = 0 ] && return 0
        sleep 1
    done
    return 1
}
last_task() { echo "$TASKS" | jq -r --arg c "$1" '[.history[] | select(.command == $c)][0] | "\(.status) \(.exit_code)"'; }
schedule() { req POST $U/schedule "{\"tasks\":[$1]}"; }
health() { curl -s $U/state | jq -r .health; }
dev() { basename "$(grep -lx "$1" /run/lab/map/* | head -1)" | sed 's|^|/dev/|'; }
format() { # NAME FSTYPE LABEL PURPOSE WIPE -> PART UUID
    req POST $S/format "{\"device\":\"$(dev "$1")\",\"fstype\":\"$2\",\"label\":\"$3\",\"purpose\":\"$4\",\"wipe\":$5}"
    [ "$CODE" = 200 ] || return 1
    job_ok || return 1
    PART=$(echo "$JOB" | jq -r .partition); UUID=$(echo "$JOB" | jq -r .uuid)
}
mount_api() { req POST $S/mount "{\"source\":\"$1\",\"target\":\"$2\",\"fstype\":\"${3:-ext4}\",\"options\":\"${4:-defaults,noatime,nofail}\",\"persist\":${5:-true}}"; }
sums() { (cd "$1" && find . -type f ! -name 'snapraid.*' -print0 | sort -z | xargs -0 -r sha256sum); }
fill() { # DIR COUNT KB
    mkdir -p "$1"
    for i in $(seq 1 "$2"); do head -c "${3}K" /dev/urandom > "$1/file-$i.bin"; done
    find "$1" -type f -exec touch -d '2 hours ago' {} +
}

for _ in $(seq 1 60); do curl -s -o /dev/null $U/state && break; sleep 1; done

# ---------------------------------------------------------------------------
section "inventory and request handling"

req GET $S
expect "inventory is served" 200
check "storage administration is allowed in the lab" test "$(echo "$BODY" | jq -r .admin)" = true
check "the tools are detected" test "$(echo "$BODY" | jq -r '.tools | .lsblk and .sfdisk and .mkfs_ext4 and .mergerfs and .rsync')" = true
check "the lab disks are listed" test "$(echo "$BODY" | jq '[.lsblk.blockdevices[] | select(.type == "loop")] | length')" -ge 5
check "no job has run yet" test "$(echo "$BODY" | jq -r .job.id)" = 0

req GET $S/format;                                   expect "GET on an action is refused" 405
req POST $S;                                         expect "POST on the inventory is refused" 405
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data '{"path":"/mnt/x"}' $S/mkdir)
check "a request without the JSON content type is refused (CSRF)" test "$CODE" = 415
req POST $S/mkdir '{"path":"/mnt/x","extra":1}';      expect "unknown fields are refused" 400
req POST $S/mkdir '{"path":';                         expect "broken JSON is refused" 400
req POST $S/mkdir '{"path":"/mnt/x","path":"/mnt/y"}'; expect "duplicate fields are refused" 400
req POST $S/mkdir '{"path":7}';                       expect "wrong types are refused" 400
req POST $S/mkdir '{"path":"/etc/cron.d/x"}';         expect "mkdir in a system directory is refused" 403 "system directory"
req POST $S/mkdir '{"path":"/mnt/a/../../etc/x"}';    expect "mkdir with .. is refused" 400
req POST $S/mkdir "{\"path\":\"$T/made/deep\"}";      expect "mkdir creates parents" 200
check "the directory exists" test -d $T/made/deep

# ---------------------------------------------------------------------------
section "format"

D1=$(dev d1); S1=$(dev s1)
req POST $S/format "{\"device\":\"$D1;reboot\",\"fstype\":\"ext4\",\"label\":\"x\",\"purpose\":\"data\",\"wipe\":false}"
expect "a device name with shell characters is refused" 400
req POST $S/format '{"device":"/dev/../etc/passwd","fstype":"ext4","label":"x","purpose":"data","wipe":false}'
expect "a device path with .. is refused" 400
req POST $S/format "{\"device\":\"$D1\",\"fstype\":\"ext4\",\"label\":\"thirteen_char\",\"purpose\":\"data\",\"wipe\":false}"
expect "a label over 12 characters is refused" 400 "label"
req POST $S/format "{\"device\":\"$D1\",\"fstype\":\"ext4\",\"label\":\"-L\",\"purpose\":\"data\",\"wipe\":false}"
expect "a label that looks like an option is refused" 400

req POST $S/format '{"device":"/dev/nosuchdisk","fstype":"ext4","label":"x","purpose":"data","wipe":false}'
job_wait; check "a missing device fails" test "$(echo "$JOB" | jq -r .success)" = false
req POST $S/format "{\"device\":\"$D1\",\"fstype\":\"ntfs\",\"label\":\"x\",\"purpose\":\"data\",\"wipe\":false}"
job_wait; check "an unsupported filesystem fails" grep -qi unsupported <<< "$(job_msg)"
check "the refused formats left the disk blank" test -z "$(blkid -p -o value -s PTTYPE "$D1")"

if format d1 ext4 d1 data false; then ok "a blank disk is formatted"; else fail "a blank disk is formatted" "$(job_msg)$(msg)"; fi
D1P=$PART; D1U=$UUID
check "it has a GPT partition table" test "$(blkid -p -o value -s PTTYPE "$D1")" = gpt
check "the partition holds ext4 with the label" test "$(blkid -p -o value -s TYPE "$D1P") $(blkid -p -o value -s LABEL "$D1P")" = "ext4 d1"
check "the reported UUID is the real one" test "$(blkid -p -o value -s UUID "$D1P")" = "$D1U"
check "no space is reserved for root" test "$(tune2fs -l "$D1P" | awk '/Reserved block count/{print $4}')" = 0

req POST $S/format "{\"device\":\"$D1\",\"fstype\":\"ext4\",\"label\":\"d1\",\"purpose\":\"data\",\"wipe\":false}"
job_wait; check "a disk with a filesystem is not formatted without wipe" grep -qi "not blank" <<< "$(job_msg)"
check "and it still has the same filesystem" test "$(blkid -p -o value -s UUID "$D1P")" = "$D1U"
req POST $S/format "{\"device\":\"$D1P\",\"fstype\":\"ext4\",\"label\":\"d1\",\"purpose\":\"data\",\"wipe\":true}"
job_wait; check "a partition is refused: only whole disks" grep -qi "partition" <<< "$(job_msg)"

if format d1 ext4 d1 data true; then ok "with wipe it is formatted again"; else fail "with wipe it is formatted again" "$(job_msg)"; fi
D1U2=$UUID
refute "the new filesystem has a new UUID" test "$D1U" = "$D1U2"
if [ ! -e /run/udev/control ]; then
    check "without udev the by-uuid link is published" test "$(readlink -f /dev/disk/by-uuid/$D1U2)" = "$D1P"
    refute "and the link of the old filesystem is gone" test -e /dev/disk/by-uuid/$D1U
fi

if format p1 ext4 parity1 parity false; then ok "a parity disk is formatted"; else fail "a parity disk is formatted" "$(job_msg)"; fi
P1U=$UUID
check "parity has fewer inodes than data (largefile4)" test "$(tune2fs -l "$PART" | awk '/^Inode count/{print $3}')" -lt "$(tune2fs -l "$D1P" | awk '/^Inode count/{print $3}')"
if [ "$(curl -s $S | jq -r .tools.mkfs_xfs)" = true ]; then
    if format d2 xfs d2 data false; then ok "xfs is supported"; else fail "xfs is supported" "$(job_msg)"; fi
    check "the partition holds xfs" test "$(blkid -p -o value -s TYPE "$PART")" = xfs
    D2FS=xfs
else
    skip "xfs is supported" "mkfs.xfs not installed"; format d2 ext4 d2 data false; D2FS=ext4
fi
D2U=$UUID
format d3 ext4 d3 data false; D3U=$UUID; D3P=$PART

# ---------------------------------------------------------------------------
section "mount and fstab"

mount_api "UUID=$D1U2" /etc/disk;                 expect "a system directory is refused as mount point" 403
mount_api "UUID=$D1U2" "/mnt/my disk";            expect "a mount point with spaces is refused" 400
mount_api "UUID=$D1U2" /;                         expect "the root is refused as mount point" 400
mount_api "UUID=$D1U2" $T/d1 ext4 'defaults 0 0\n/dev/sda1 / ext4 defaults'
expect "options with spaces or newlines are refused (fstab injection)" 400
mount_api "//server/share" $T/d1 cifs;            expect "network sources are refused" 400
mount_api "UUID=$D1U2" $T/d1 fuse.mergerfs;       expect "pools are not mounted through mount" 400
mount_api "UUID=00000000-0000-0000-0000-000000000000" $T/ghost
expect "an unknown filesystem fails to mount" 500
refute "and leaves nothing in fstab" grep -q "$T/ghost" /etc/fstab
cp /etc/fstab /tmp/fstab.before

mount_api "UUID=$D1U2" $T/d1;                     expect "a filesystem is mounted" 200
check "it is really mounted" mountpoint -q $T/d1
check "fstab has its line" grep -qE "^UUID=$D1U2 $T/d1 ext4 defaults,noatime,nofail 0 2$" /etc/fstab
check "the previous fstab is kept as backup" cmp -s /tmp/fstab.before "$(readlink -f /etc/fstab).snapraidd.bak"
mount_api "UUID=$D1U2" $T/d1;                     expect "mounting on a used mount point is refused" 409 "already mounted"
mount_api "UUID=$D1U2" $T/d1-again;               expect "the same filesystem is not mounted twice" 409 "already mounted at $T/d1"
mkdir -p $T/full && touch $T/full/file
mount_api "UUID=$D2U" $T/full "$D2FS";            expect "mounting over a folder with files is refused" 409 "not empty"
rm -rf $T/full

mount_api "UUID=$D2U" $T/d2 "$D2FS";              expect "second data disk mounted" 200
mount_api "UUID=$D3U" $T/d3;                      expect "third data disk mounted" 200
mount_api "UUID=$P1U" $T/p1;                      expect "parity disk mounted" 200
mount_api "UUID=$P1U" $T/tmp ext4 defaults false; expect "cannot mount parity a second time" 409

# the empty mount point is protected: with the disk missing nothing can be written there
umount $T/d3
if lsattr -d $T/d3 2>/dev/null | cut -d' ' -f1 | grep -q i; then
    refute "an unmounted mount point refuses files (immutable)" touch $T/d3/file
else
    skip "an unmounted mount point refuses files (immutable)" "this filesystem has no immutable flag"
fi
mount $T/d3
check "fstab alone is enough to mount it back" mountpoint -q $T/d3

req POST $S/unmount "{\"target\":\"$T/nothing\",\"forget\":false}"; expect "unmounting what is not mounted is an error" 409
req POST $S/unmount '{"target":"/","forget":true}';                 expect "the root cannot be unmounted" 400
req POST $S/unmount '{"target":"/etc","forget":true}';              expect "system directories cannot be unmounted" 403
mount_api "UUID=$(blkid -p -o value -s UUID "$D3P")" $T/d3;         expect "d3 is still mounted" 409
S1DEV=$S1
format s1 ext4 spare data false; S1U=$UUID
mount_api "UUID=$S1U" $T/s1;                      expect "a spare is mounted" 200
req POST $S/unmount "{\"target\":\"$T/s1\",\"forget\":true}"; expect "unmount and forget" 200
refute "it is no more mounted" mountpoint -q $T/s1
refute "fstab has no line for it" grep -q " $T/s1 " /etc/fstab
check "the other lines are untouched" test "$(grep -c " $T/" /etc/fstab)" = 4
check "the forgotten mount point is writable again" touch $T/s1/file
rm -f $T/s1/file

# ---------------------------------------------------------------------------
section "SnapRAID configuration"

CONF=$(curl -s $S | jq -r .engine_conf.path)
req PUT $S/engine_conf '{"text":""}';             expect "an empty configuration is refused" 400
req PUT $S/engine_conf '{"text":"data d1 /mnt/x\u0001\n"}'; expect "control characters are refused" 400
req POST $S/engine_conf '{"text":"x"}';           expect "the configuration is replaced only with PUT" 405
TEXT="# written by the tests\nparity $T/p1/snapraid.parity\ncontent $LAB/etc/snapraid.content\ncontent $T/d1/snapraid.content\ndata d1 $T/d1\ndata d2 $T/d2\ndata d3 $T/d3\nexclude *.tmp\nexclude /lost+found/\n"
req PUT $S/engine_conf "{\"text\":\"$TEXT\"}";    expect "the configuration is written" 200
check "the file has the text" grep -q "^data d3 $T/d3$" "$CONF"
check "the inventory returns it" test "$(curl -s $S | jq -r .engine_conf.text | head -1)" = "# written by the tests"
req PUT $S/engine_conf "{\"text\":\"$TEXT# second\\n\"}"; expect "it is written again" 200
check "the previous one is kept as .snapraidd.bak" test "$(tail -1 "$CONF.snapraidd.bak")" = "exclude /lost+found/"

fill $T/d1/Movies 12 3000; fill $T/d1/Music 30 200; fill $T/d2/Photos 40 150; fill $T/d3/Docs 25 60
fill $T/d2/Movies/extra 2 2000
schedule '{"command":"probe"},{"command":"sync"}';  expect "probe and sync are scheduled" 202
tasks_wait; check "the first sync succeeds" test "$(last_task sync)" = "terminated 0"
check "the array is not degraded" test "$(health)" != degraded
check "the parity file exists" test -s $T/p1/snapraid.parity

# ---------------------------------------------------------------------------
section "mergerfs pool"

POOL=$T/pool
OPTS="cache.files=off,category.create=pfrd,func.getattr=newest,dropcacheonclose=false,minfreespace=10M,moveonenospc=true,fsname=mergerfs,allow_other"
pool() { req POST $S/pool "{\"mountpoint\":\"$1\",\"branches\":\"$2\",\"options\":\"${3:-$OPTS}\",\"persist\":true}"; }
pool /etc/pool "$T/d1:$T/d2";                     expect "a pool in a system directory is refused" 403
pool $POOL "$T/d1:$T/nowhere";                    expect "a branch that does not exist is refused" 400 "not an existing directory"
pool $T/d1/pool "$T/d1:$T/d2";                    expect "a pool inside one of its branches is refused" 400 "overlap"
pool $T "$T/d1:$T/d2";                            expect "a pool containing its branches is refused" 400 "overlap"
pool $POOL "$T/d1:$T/d2:$T/d1";                   expect "a branch listed twice is refused" 400 "twice"
pool $POOL "$T/d1:$T/d2:$T/p1";                   expect "the parity disk is refused as branch" 400 "parity"
pool $POOL "$T/d1:$T/d2" "allow_other,x=\$(id)";  expect "options with shell characters are refused" 400
pool $POOL "";                                    expect "a pool without branches is refused" 400
refute "nothing was mounted by the refused requests" mountpoint -q $POOL

pool $POOL "$T/d1:$T/d2";                         expect "a pool is created" 200
check "it is a mergerfs mount" test "$(findmnt -n -o FSTYPE $POOL)" = fuse.mergerfs
check "files of both disks are visible" test -f $POOL/Movies/file-1.bin -a -f $POOL/Photos/file-1.bin
check "a folder on two disks is merged" test "$(ls $POOL/Movies | wc -l)" = 13
check "fstab has the pool after the disks" test "$(grep -n mergerfs /etc/fstab | cut -d: -f1)" -gt "$(grep -n " $T/d2 " /etc/fstab | cut -d: -f1)"
check "the inventory reports the pool" test "$(curl -s $S | jq -r '.pools[0].branches | map(.path) | join(":")')" = "$T/d1:$T/d2"

MID=$(findmnt -n -o ID $POOL)
pool $POOL "$T/d1:$T/d2:$T/d3" "${OPTS/pfrd/mfs}"; expect "a mounted pool is changed" 200
check "without being remounted" test "$(findmnt -n -o ID $POOL)" = "$MID"
check "the new branch is active" test -f $POOL/Docs/file-1.bin
check "the policy changed on the fly" test "$(getfattr --only-values -n user.mergerfs.category.create $POOL/.mergerfs)" = mfs
check "fstab has one pool line, updated" test "$(grep -c mergerfs /etc/fstab) $(grep mergerfs /etc/fstab | cut -d' ' -f1)" = "1 $T/d1:$T/d2:$T/d3"
pool $POOL "$T/d1:$T/d2:$T/d3" "${OPTS/pfrd/nosuchpolicy}"; expect "a policy mergerfs does not know is reported" 400 "refused"
mount_api "UUID=$S1U" $T/s1;                      expect "a new disk mounted after the pool exists" 200
check "its fstab line is placed before the pool" test "$(grep -n " $T/s1 " /etc/fstab | cut -d: -f1)" -lt "$(grep -n mergerfs /etc/fstab | cut -d: -f1)"
req POST $S/unmount "{\"target\":\"$T/s1\",\"forget\":true}"

# ---------------------------------------------------------------------------
section "where the files are"

req GET "$S/browse?pool=$POOL&path=/";            expect "the pool can be browsed" 200
check "folders are listed with their disks" test "$(echo "$BODY" | jq -c '.entries[] | select(.name == "Movies") | .on')" = "[0,1]"
check "SnapRAID's own files are hidden" test "$(echo "$BODY" | jq '[.entries[] | select(.name | startswith("snapraid."))] | length')" = 0
req GET "$S/browse?pool=$POOL&path=/Docs";        expect "a sub folder can be browsed" 200
check "files are on one disk" test "$(echo "$BODY" | jq -c '[.entries[] | .on] | unique')" = "[[2]]"
req GET "$S/browse?pool=$POOL&path=/../../etc";   expect "climbing out of the pool is refused" 400
req GET "$S/browse?pool=$POOL&path=/Docs/..";     expect "a final .. is refused" 400
req GET "$S/browse?pool=/etc&path=/";             expect "browsing something that is not a pool is refused" 400
req GET "$S/browse?pool=$POOL";                   expect "a missing path is refused" 400
mkdir -p "$T/d1/Odd names" && echo x > "$T/d1/Odd names/it's \"quoted\" & <tagged>.txt"
req GET "$S/browse?pool=$POOL&path=/Odd%20names"; expect "names with spaces and quotes are served" 200
check "as valid JSON, unchanged" test "$(echo "$BODY" | jq -r '.entries[0].name')" = "it's \"quoted\" & <tagged>.txt"

# ---------------------------------------------------------------------------
section "duplicates"

cp -p $T/d1/Music/file-1.bin $T/d3/Docs/file-1.bin.copy            # different name: not a duplicate
mkdir -p $T/d3/Music && cp -p $T/d1/Music/file-2.bin $T/d3/Music/file-2.bin
mkdir -p $T/d2/Music && head -c 1000 /dev/urandom > $T/d2/Music/file-3.bin   # same path, different content
req POST $S/duplicates '{"mountpoint":"/etc"}';   expect "duplicates on something that is not a pool is refused" 400
req POST $S/duplicates "{\"mountpoint\":\"$POOL\"}"; expect "the search starts" 200
job_wait
check "it finds the two duplicated paths" test "$(echo "$JOB" | jq -r .found)" = 2
check "with both copies of each" test "$(echo "$JOB" | jq -c '[.result[] | .copies | length]')" = "[2,2]"
check "and the size of every copy" test "$(echo "$JOB" | jq -r '.result[] | select(.path == "/Music/file-3.bin") | .copies | map(.size) | unique | length')" = 2
rm -f $T/d3/Music/file-2.bin $T/d2/Music/file-3.bin $T/d3/Docs/file-1.bin.copy; rmdir $T/d3/Music $T/d2/Music 2>/dev/null

# ---------------------------------------------------------------------------
section "balance"

fill $T/d1/Bulk 30 3000                                             # d1 much fuller than the others
ln $T/d1/Bulk/file-1.bin $T/d1/Bulk/hardlink.bin                    # hard links must stay together
head -c 2000K /dev/urandom > $T/d1/Bulk/just-written.bin            # being written right now
mkdir -p $T/d3/Bulk && echo "other content" > $T/d3/Bulk/file-2.bin # same name on the target
mkdir -p $T/d2/Bulk && echo "other content" > $T/d2/Bulk/file-2.bin
touch -d '2 hours ago' $T/d3/Bulk/file-2.bin $T/d2/Bulk/file-2.bin
BEFORE=$(sums $T/d1; sums $T/d2; sums $T/d3)
COUNT=$(find $T/d1 $T/d2 $T/d3 -type f ! -name 'snapraid.*' | wc -l)
fillpct() { df --output=pcent "$1" | tail -1 | tr -dc 0-9; }
SPREAD0=$(( $(fillpct $T/d1) - $(fillpct $T/d3) ))

req POST $S/balance '{"mountpoint":"/etc","max_bytes":"1000000","spread":"5"}';     expect "balancing something that is not a pool is refused" 400
req POST $S/balance "{\"mountpoint\":\"$POOL\",\"max_bytes\":\"0\",\"spread\":\"5\"}"; expect "balancing nothing is refused" 400
req POST $S/balance "{\"mountpoint\":\"$POOL\",\"max_bytes\":\"1000000\",\"spread\":\"0\"}"; expect "a zero spread is refused" 400
req POST $S/balance "{\"mountpoint\":\"$POOL\",\"max_bytes\":\"4000000\",\"spread\":\"5\"}"; expect "a capped balance starts" 200
job_wait
check "it stops at the requested amount" test "$(echo "$JOB" | jq -r '.bytes <= 4000000 and .success')" = true

req POST $S/balance "{\"mountpoint\":\"$POOL\",\"max_bytes\":\"900000000\",\"spread\":\"5\"}"; expect "a full balance starts" 200
req POST $S/mkdir "{\"path\":\"$T/busy\"}"
mount_api "UUID=$S1U" $T/s1
if [ "$(curl -s $S/job | jq -r .job.running)" = true ] || [ "$CODE" = 409 ]; then
    check "other changes wait while a job runs" test "$CODE" = 409
else
    skip "other changes wait while a job runs" "the balance finished too quickly"
    req POST $S/unmount "{\"target\":\"$T/s1\",\"forget\":true}"
fi
req POST $S/duplicates "{\"mountpoint\":\"$POOL\"}"
[ "$CODE" = 409 ] && ok "a second job is refused while one runs" || skip "a second job is refused while one runs" "the balance finished too quickly"
job_wait
check "the balance completes" test "$(echo "$JOB" | jq -r '.kind + " " + (.success | tostring)')" = "balance true"
SPREAD1=$(( $(fillpct $T/d1) - $(fillpct $T/d3) ))
check "the disks are closer than before ($SPREAD0 -> $SPREAD1 points)" test "$SPREAD1" -lt "$SPREAD0"
check "files were moved" test "$(echo "$JOB" | jq -r .files)" -gt 0
check "no file was lost or added" test "$(find $T/d1 $T/d2 $T/d3 -type f ! -name 'snapraid.*' | wc -l)" = "$COUNT"
check "every file has the same content as before" test "$( (sums $T/d1; sums $T/d2; sums $T/d3) | sort)" = "$(echo "$BEFORE" | sort)"
check "the hard linked file stayed with its link" test "$(stat -c %h $T/d1/Bulk/file-1.bin)" = 2
check "the file being written was not touched" test -f $T/d1/Bulk/just-written.bin
check "a file with the same name on the target was not overwritten" test "$(cat $T/d3/Bulk/file-2.bin)" = "other content"
check "modification times are preserved" test -z "$(find $T/d2/Bulk $T/d3/Bulk -name 'file-*.bin' -newermt '1 hour ago' 2>/dev/null)"
check "SnapRAID's content file was not moved" test -f $T/d1/snapraid.content
req POST $S/job_stop '{}';                        expect "stopping when nothing runs is an error" 409

schedule '{"command":"sync"}'; tasks_wait
check "the sync after the balance succeeds" test "$(last_task sync)" = "terminated 0"

# ---------------------------------------------------------------------------
section "recovery of a replaced disk"

WANT=$(sums $T/d2)
D2P=$(findmnt -n -o SOURCE $T/d2)
req POST $S/recover '{"disks":"-U","check":true}';             expect "an option instead of a disk name is refused" 400
req POST $S/recover '{"disks":"d2;reboot","check":true}';      expect "a disk name with shell characters is refused" 400
req POST $S/recover '{"disks":"","check":true}';               expect "a recovery without disks is refused" 400

# the disk dies and a new empty one takes its place
umount $POOL 2>/dev/null; umount $T/d2
mkfs.ext4 -q -F -m 0 -L d2 "$D2P"
NEWU=$(blkid -p -o value -s UUID "$D2P")
find /dev/disk/by-uuid -type l -lname "$D2P" -delete; ln -sf "$D2P" /dev/disk/by-uuid/$NEWU
sed -i --follow-symlinks "s|^UUID=$D2U $T/d2 [a-z0-9]* |UUID=$NEWU $T/d2 ext4 |" /etc/fstab
mount $T/d2; mount $POOL 2>/dev/null
check "the replaced disk is empty" test "$(find $T/d2 -type f | wc -l)" = 0

schedule '{"command":"probe"}'; tasks_wait
check "the array is degraded" test "$(health)" = degraded
schedule '{"command":"sync"}'; tasks_wait
check "a normal sync is not allowed on a degraded array" test "$(last_task sync | cut -d' ' -f1)" = canceled
check "and nothing was synced over the lost data" test "$(find $T/d2 -type f | wc -l)" = 0
schedule '{"command":"fix","args":["-d","d2"]}'; tasks_wait
check "a plain fix stays blocked too: only the recovery goes through" test "$(last_task fix | cut -d' ' -f1)" = canceled

req POST $S/recover '{"disks":"d2","check":true}';             expect "the recovery is scheduled" 200
req POST $S/recover '{"disks":"d2","check":true}';             expect "a second recovery is refused while one is queued" 409
tasks_wait
check "fix succeeded"   test "$(last_task fix)"   = "terminated 0"
check "check succeeded" test "$(last_task check)" = "terminated 0"
check "sync succeeded"  test "$(last_task sync)"  = "terminated 0"
check "every file is back with the same content" test "$(sums $T/d2)" = "$WANT"
check "nothing was unrecoverable" test -z "$(find $T/d2 -name '*.unrecoverable')"
check "the array is no more degraded" test "$(health)" != degraded
schedule '{"command":"sync"}'; tasks_wait
check "normal syncs work again" test "$(last_task sync)" = "terminated 0"

# ---------------------------------------------------------------------------
section "permission to change the storage"

DCONF=$LAB/etc/snapraidd.conf; PID=$(pgrep -n -x snapraidd)
cp $DCONF /tmp/snapraidd.conf.keep
sed -i 's/^net_storage_admin = 1/net_storage_admin = 0/' $DCONF; kill -HUP "$PID"; sleep 2
req POST $S/mkdir "{\"path\":\"$T/denied\"}";      expect "with net_storage_admin = 0 changes are refused" 403 "net_storage_admin"
req PUT $S/engine_conf '{"text":"# no\n"}';        expect "also the configuration" 403
req POST $S/recover '{"disks":"d1","check":false}'; expect "also the recovery" 403
req GET $S;                                         expect "the inventory is still readable" 200
check "and says it is read-only" test "$(echo "$BODY" | jq -r .admin)" = false
refute "nothing was created" test -e $T/denied

sed -i 's/^net_storage_admin = 0/net_storage_admin = 1/; /^net_acl/d; /^net_auth_credential/d' $DCONF; kill -HUP "$PID"; sleep 2
req POST $S/mkdir "{\"path\":\"$T/denied\"}"
expect "open to the network without credentials or access list: refused even with the option on" 403 "without protection"
cp /tmp/snapraidd.conf.keep $DCONF; kill -HUP "$PID"; sleep 2
req POST $S/mkdir "{\"path\":\"$T/allowed\"}";     expect "with the access list back, changes work again" 200

# ---------------------------------------------------------------------------
echo
echo "passed $PASS, failed $FAILS, skipped $SKIP"
exit $FAILS
