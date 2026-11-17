#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Checks the showcase lab: three arrays on disks of different sizes, kinds and filesystems, a
# split parity, snapshots, the less common options of snapraid.conf and of the daemon, the hook,
# the notifications, the temperature limit and the login.
#
# It works on the lab of docker-compose.yml as it is after the first start, and leaves it
# healthy. It runs a maintenance of every array and changes SMART profiles for a while:
#
#     docker compose -f docker-compose.showcase.yml up --build --abort-on-container-exit --exit-code-from tests
#
# LAB_TEST_SLOW=0 skips the temperature limit, which waits the three minutes of temp_sleep.
# Every test prints "ok" or "FAIL" with the reason; the exit code is the number of failures.

U=http://127.0.0.1:7627/snapraid/v1
V2=http://127.0.0.1:7627/snapraid/v2
S=$U/storage
AM=$U/arrays/media
AF=$U/arrays/flash
LAB=${LAB_DIR:-/lab}
D=/mnt/lab
PASS=0; FAILS=0; SKIP=0
CODE=; BODY=

[ "$(cat $LAB/etc/lab-preset 2>/dev/null)" = ready ] || { echo "refusing to run: this lab was not started with LAB_PRESET=ready"; exit 99; }
[ "$(cat $LAB/etc/lab-showcase 2>/dev/null)" = 1 ] || { echo "refusing to run: this lab was not started with LAB_SHOWCASE=1"; exit 99; }
for d in d1 d2 d3 d4 p1 p2 s1 s2 m1 m2 q1 q2 f1 f2 f3 g1 x1 u1; do grep -qx "$d" $LAB/etc/lab-disks || { echo "refusing to run: the lab has no disk $d"; exit 99; }; done

ok()   { PASS=$((PASS + 1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; }
skip() { SKIP=$((SKIP + 1)); echo "skip  $1 ($2)"; }
section() { echo; echo "== $1"; }
req() { # METHOD URL [JSON]
    local out
    if [ $# -ge 3 ]; then
        out=$(curl -s -m 600 -w '\n%{http_code}' -X "$1" -H 'Content-Type: application/json' --data-binary "$3" "$2")
    else
        out=$(curl -s -m 600 -w '\n%{http_code}' -X "$1" "$2")
    fi
    CODE=${out##*$'\n'}; BODY=${out%$'\n'*}
}
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "failed: $*"; fi; }
is() { # NAME ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "got '$2' instead of '$3'"; fi
}
get() { curl -s -m 60 "$1"; }
tasks_wait() { # BASE -> TASKS
    sleep 2
    for _ in $(seq 1 900); do
        TASKS=$(get "$1/tasks")
        [ "$(echo "$TASKS" | jq '(.active | length) + (.pending | length)')" = 0 ] && return 0
        sleep 1
    done
    return 1
}
last_task() { echo "$TASKS" | jq -r --arg c "$1" '[.history[] | select(.command == $c)][0] | "\(.status) \(.exit_code)"'; }
health() { get "$1/state" | jq -r .health; }
maintenance() { req POST "$1/maintenance" '{}'; }
# device of a disk, as the daemon reports it: BASE NAME [INDEX] -> one JSON object
device() { get "$1/disks" | jq -c --arg n "$2" --argjson i "${3:-0}" '[.data_disks[], .parity_disks[], .extra_disks[]] | map(select(.name == $n)) | [.[].devices[]] | .[$i]'; }
field() { device "$1" "$2" "${4:-0}" | jq -r ".$3"; }
probe_wait() { # BASE NAME JQ-FILTER: until the device of the disk satisfies the filter (the probe runs every minute)
    for _ in $(seq 1 150); do
        [ "$(device "$1" "$2" | jq "$3" 2>/dev/null)" = true ] && return 0
        sleep 1
    done
    return 1
}
lsblk_of() { # DISK FIELD, from the inventory of the Storage page
    local loop; loop=$(basename "$(grep -lx "$1" /run/lab/map/* | head -1)")
    echo "$INV" | jq -r --arg n "$loop" ".lsblk.blockdevices[] | select(.name == \$n) | .$2"
}
mount_of() { echo "$INV" | jq -r --arg t "$D/$1" ".mounts[] | select(.target == \$t) | .$2"; }
conf_has() { grep -qE "^$2" "$1"; }

for _ in $(seq 1 60); do curl -s -o /dev/null $U/state && break; sleep 1; done
tasks_wait $U; tasks_wait $AM; tasks_wait $AF

# ---------------------------------------------------------------------------
section "three arrays in one daemon"

req GET $U/arrays
is "the three arrays are listed" "$(echo "$BODY" | jq -r '[.arrays[].name] | sort | join(",")')" default,flash,media
for a in $U $AM $AF; do is "the array ${a##*/} is healthy" "$(health $a)" passed; done
ARR=$(get $U/array)
is "default: four data disks" "$(echo "$ARR" | jq .data_disks_count)" 4
is "default: two parity levels" "$(echo "$ARR" | jq .parity_disks_count)" 2
is "default: two disks watched but not in the array" "$(echo "$ARR" | jq .extra_disks_count)" 2
is "media: two data disks" "$(get $AM/array | jq .data_disks_count)" 2
is "media: one parity level" "$(get $AM/array | jq .parity_disks_count)" 1
is "flash: three data disks" "$(get $AF/array | jq .data_disks_count)" 3
is "the arrays may run together" "$(get $V2/config | jq .array_parallel)" true

# ---------------------------------------------------------------------------
section "disks of different sizes"

for kv in $(cat $LAB/etc/lab-sizes); do
    d=${kv%%=*}
    is "$d is ${kv#*=} MB" "$(( $(stat -c %s $LAB/img/$d.img) / 1048576 ))" "${kv#*=}"
done
check "a spare is larger than the parity of the default array" test "$(stat -c %s $LAB/img/s1.img)" -gt "$(stat -c %s $LAB/img/p1.img)"
check "the data disks of the default array are all different" test "$(for d in d1 d2 d3 d4; do stat -c %s $LAB/img/$d.img; done | sort -u | wc -l)" = 4

# ---------------------------------------------------------------------------
section "kinds of disk, as SnapRAID reads them from SMART"

is "d1 is a SATA disk" "$(field $U d1 interface)" SATA
check "d1 rotates" test "$(field $U d1 rotational)" -gt 0
is "d2, shingled, is a SATA disk" "$(field $U d2 interface)" SATA
check "d2 is of the Archive family" sh -c "grep -q 'SMR' $LAB/smart/d2.env"
# SnapRAID 15.1 calls SCSI every disk that answers in the SCSI format, SAS included
is "d3 answers in the SCSI format" "$(field $U d3 interface)" SCSI
is "d3 rotates at 7200 rpm" "$(field $U d3 rotational)" 7200
check "d3 reports its grown defects" test "$(device $U d3 | jq '[.smart.attributes[] | select(.name == "Elements_In_Grown_Defect_List")][0].raw')" = "$(. $LAB/smart/d3.env; echo $REALLOCATED)"
is "d4 is a SATA SSD" "$(field $U d4 interface)/$(field $U d4 rotational)" SATA/0
is "f1 is an NVMe disk" "$(field $AF f1 interface)/$(field $AF f1 rotational)" NVMe/0
is "f2 is an NVMe disk" "$(field $AF f2 interface)" NVMe
is "f3 is a SATA SSD" "$(field $AF f3 interface)/$(field $AF f3 rotational)" SATA/0
is "the parity of flash is an NVMe disk" "$(field $AF parity interface)" NVMe
check "an NVMe disk reports its wear" test "$(field $AF f1 wear_level)" -ge 1
check "an NVMe disk reports its spare" test "$(device $AF f1 | jq '[.smart.attributes[] | select(.name == "Available_Spare")][0].raw')" = 100
for d in d1 d2 d3 d4 parity 2-parity x1 u1; do check "default: $d has a model and a serial" test -n "$(field $U $d model)" -a -n "$(field $U $d serial)"; done
for d in f1 f2 f3 parity; do check "flash: $d has a model and a serial" test -n "$(field $AF $d model)" -a -n "$(field $AF $d serial)"; done
is "the USB disk is watched by the default array" "$(get $U/disks | jq -r '[.extra_disks[].name] | sort | join(",")')" u1,x1

# ---------------------------------------------------------------------------
section "kinds of disk, in the inventory of the Storage page"

INV=$(get $S)
is "d1 is on SATA and rotates" "$(lsblk_of d1 tran)/$(lsblk_of d1 rota)" sata/true
is "d3 is on SAS" "$(lsblk_of d3 tran)" sas
is "d4 is an SSD" "$(lsblk_of d4 tran)/$(lsblk_of d4 rota)" sata/false
is "f1 is on NVMe" "$(lsblk_of f1 tran)/$(lsblk_of f1 rota)" nvme/false
is "the blank spare s2 is a removable USB disk" "$(lsblk_of s2 tran)/$(lsblk_of s2 rm)" usb/true
is "u1 is a removable USB disk" "$(lsblk_of u1 tran)/$(lsblk_of u1 rm)" usb/true
check "the blank spare s1 has a model" test -n "$(lsblk_of s1 model)"
is "the inventory has the same model SMART gives" "$(lsblk_of d1 model)" "$(field $U d1 model)"
check "the real lsblk still answers without --json" sh -c "lsblk -n -o NAME | grep -q loop"

# ---------------------------------------------------------------------------
section "filesystems"

is "d1 is ext4" "$(mount_of d1 fstype)" ext4
is "d2 is xfs" "$(mount_of d2 fstype)" xfs
is "d4 is btrfs" "$(mount_of d4 fstype)" btrfs
is "m1 and m2 are xfs" "$(mount_of m1 fstype)/$(mount_of m2 fstype)" xfs/xfs
is "f1, f2 and f3 are btrfs" "$(mount_of f1 fstype)/$(mount_of f2 fstype)/$(mount_of f3 fstype)" btrfs/btrfs/btrfs
is "the parity disks are ext4" "$(mount_of p1 fstype)/$(mount_of q1 fstype)/$(mount_of g1 fstype)" ext4/ext4/ext4
is "an array mixes three filesystems" "$(for d in d1 d2 d3 d4; do mount_of $d fstype; done | sort -u | wc -l)" 3

# ---------------------------------------------------------------------------
section "pools and mounts, and what protects them"

is "four pools" "$(echo "$INV" | jq -r '[.pools[].mountpoint] | sort | join(",")')" /mnt/flash,/mnt/media,/mnt/scratch,/mnt/storage
pool_arrays() { echo "$INV" | jq -r --arg m "$1" '.pools[] | select(.mountpoint == $m) | [.branches[] | "\(.array // "none"):\(.protected)"] | unique | join(",")'; }
is "/mnt/storage is protected by the default array" "$(pool_arrays /mnt/storage)" default:true
is "/mnt/media is protected by the array media" "$(pool_arrays /mnt/media)" media:true
is "/mnt/flash is protected by the array flash" "$(pool_arrays /mnt/flash)" flash:true
is "/mnt/scratch has no parity" "$(pool_arrays /mnt/scratch)" none:false
is "the USB disk is mounted, in no array" "$(mount_of u1 fstype)/$(mount_of u1 array)" ext4/null
check "the USB disk is in no pool" sh -c "! grep -E 'mergerfs' /proc/self/mounts | grep -q '$D/u1'"
check "a file written to a pool lands on one of its disks" sh -c "echo x > /mnt/flash/showcase-test.txt && ls $D/f?/showcase-test.txt && rm /mnt/flash/showcase-test.txt"

# ---------------------------------------------------------------------------
section "a parity split over two disks"

MC=$LAB/etc/snapraid/media.conf
check "the parity of media names two files" grep -qE '^parity /mnt/lab/q1/snapraid.parity,/mnt/lab/q2/snapraid.parity$' $MC
is "the array reports the two halves" "$(get $AM/disks | jq '[.parity_disks[] | select(.name == "parity") | .splits[]] | length')" 2
check "the first half filled its disk" test "$(df --output=avail -k $D/q1 | tail -1)" -lt 4096
check "the second half is in use" test "$(stat -c %s $D/q2/snapraid.parity)" -gt 1048576
check "each half is smaller than the largest data disk" test "$(stat -c %s $LAB/img/q2.img)" -lt "$(stat -c %s $LAB/img/m1.img)"
check "the two halves together hold the fullest data disk" test "$(( $(stat -c %s $D/q1/snapraid.parity) + $(stat -c %s $D/q2/snapraid.parity) ))" -ge "$(( $(df --output=used -k $D/m2 | tail -1) * 512 ))"

# ---------------------------------------------------------------------------
section "options of snapraid.conf"

C=$LAB/etc/snapraid.conf
for o in "extra x1 " "extra u1 " nohidden "exclude \*.unrecoverable" "exclude /Downloads/incomplete/" "blocksize 256" "hashsize 16" "temp_limit 55" "temp_sleep 3" "pool " "smartctl d3 -d scsi %s" "smartctl u1 -d sat %s" "smartignore \* Spin_Up_Time" "smartignore d3 " "autosave 1" "2-parity "; do
    check "default: '${o% }' is set" conf_has $C "$o"
done
check "flash: snapshot is set" conf_has $LAB/etc/snapraid/flash.conf snapshot
for c in $C $MC $LAB/etc/snapraid/flash.conf; do
    check "SnapRAID accepts $(basename $c)" snapraid -c $c status
done
is "the block size is the one of the configuration" "$(echo "$ARR" | jq .block_size_bytes)" 262144
echo hidden > $D/d1/.showcase-hidden; mkdir -p $D/d1/Downloads/incomplete; echo part > $D/d1/Downloads/incomplete/a.bin; echo x > $D/d1/showcase.part
DIFF=$(snapraid -c $C diff 2>/dev/null)
check "hidden files are not protected (nohidden)" sh -c "! echo '$DIFF' | grep -q showcase-hidden"
check "excluded folders and patterns are not protected" sh -c "! echo '$DIFF' | grep -qE 'incomplete|showcase.part'"
rm -rf $D/d1/.showcase-hidden $D/d1/Downloads $D/d1/showcase.part
check "the folder of links has the files of the array" sh -c "find $LAB/links -type l | head -1 | grep -q ."
check "a link points into a data disk" sh -c "readlink \"\$(find $LAB/links -type l | head -1)\" | grep -q '^$D/d'"
check "the SAS disk is asked with the options of 'smartctl'" grep -q -- '-d scsi /dev/loop' /run/lab/args/d3
check "the USB disk too" grep -q -- '-d sat /dev/loop' /run/lab/args/u1
check "the others are asked without options" sh -c "! grep -q -- ' -d ' /run/lab/args/d1"

# ---------------------------------------------------------------------------
section "options of the daemon"

CFG=$(get $V2/config); CFM=$(get $AM/config); CFF=$(get $AF/config)
is "default: two schedules" "$(echo "$CFG" | jq -r .maintenance_schedule)" "02:00, Sun 05:00"
is "default: parity disks spun down later than data disks" "$(echo "$CFG" | jq -r .spindown_idle_minutes)" "15, 30"
is "default: prehash" "$(echo "$CFG" | jq .sync_prehash)" true
is "default: truncations stop a sync" "$(echo "$CFG" | jq .sync_prevent_truncations)" true
is "default: every result is notified" "$(echo "$CFG" | jq -r .notify_result_level)" info
check "default: the hook is set" test "$(echo "$CFG" | jq -r .hook_script)" = /usr/local/share/lab/hook.sh
is "media: its own schedule" "$(echo "$CFM" | jq -r .maintenance_schedule)" "Wed 03:00, Sat 03:00"
is "media: its own scrub plan" "$(echo "$CFM" | jq .scrub_percentage)" 12
is "flash: twice a day" "$(echo "$CFF" | jq -r .maintenance_schedule)" "01:00, 13:00"
is "flash: no spin down" "$(echo "$CFF" | jq -r .spindown_idle_minutes)" 0
is "flash: no sync threshold" "$(echo "$CFF" | jq '.sync_threshold_deletes + .sync_threshold_updates')" 0
is "flash: a full scrub at every run" "$(echo "$CFF" | jq .scrub_percentage)" 100
check "the logs of the commands are compressed" sh -c "ls $LAB/log/*.log.gz $LAB/log/media/*.log.gz $LAB/log/flash/*.log.gz"
check "sys_smartignore is set" grep -q '^sys_smartignore = \* Spin_Up_Time Raw_Read_Error_Rate' $LAB/etc/snapraidd.conf

# ---------------------------------------------------------------------------
section "a maintenance of every array: hook and notifications"

lab inbox clear >/dev/null; : > $LAB/notify/hooks.log
lab churn >/dev/null
maintenance $U;  is "default: maintenance accepted" "$CODE" 202
maintenance $AM; is "media: maintenance accepted" "$CODE" 202
maintenance $AF; is "flash: maintenance accepted" "$CODE" 202
for a in $U $AM $AF; do
    n=${a##*/}; [ "$a" = "$U" ] && n=default
    check "$n: the tasks end" tasks_wait $a
    is "$n: the sync ended well" "$(last_task sync)" "terminated 0"
    is "$n: the scrub ended well" "$(last_task scrub)" "terminated 0"
    is "$n: healthy" "$(health $a)" passed
    check "$n: the hook was called before" grep -q " $n task-begin" $LAB/notify/hooks.log
    check "$n: the hook was called after" grep -q " $n task-end" $LAB/notify/hooks.log
done
sleep 2
INBOX=$(lab inbox)
is "three starts were notified" "$(echo "$INBOX" | grep -c ' start ')" 3
check "a start names its array" sh -c "echo '$INBOX' | grep -q 'Maintenance of media'"
is "three heartbeats were sent" "$(echo "$INBOX" | grep -c ' heartbeat ')" 3
check "the default array notifies a good result too" sh -c "echo '$INBOX' | grep ' result ' | grep -q 'INFO'"
check "a result carries the report" sh -c "grep -l '^Kind: result' $LAB/notify/inbox/*.txt | head -1 | xargs grep -qiE 'sync|scrub'"
check "media and flash keep quiet about a good result" test "$(echo "$INBOX" | grep -c ' result ')" = 1
check "the prehash was used" sh -c "zcat -f \$(ls -t $LAB/log/*sync* | head -1) | grep -qE 'argv:[0-9]+:(-h|--pre-hash)'"

# ---------------------------------------------------------------------------
section "snapshots of the Btrfs disks"

check "the sync of flash left a snapshot on f1" test -d $D/f1/.snapraid/stable
check "and on f2 and f3" test -d $D/f2/.snapraid/stable -a -d $D/f3/.snapraid/stable
check "the snapshot cannot be written" sh -c "! touch $D/f1/.snapraid/stable/x 2>/dev/null"
F=$(find $D/f1/Photos $D/f1/Music -type f 2>/dev/null | head -1); REL=${F#$D/f1/}
SUM=$(sha256sum < "$F")
rm -f "$F"
check "a file deleted after the sync is still in the snapshot" test -f "$D/f1/.snapraid/stable/$REL"
is "with its content" "$(sha256sum < "$D/f1/.snapraid/stable/$REL")" "$SUM"
check "the default array, without the option, takes no snapshot of its Btrfs disk" test ! -e $D/d4/.snapraid
maintenance $AF; tasks_wait $AF
is "the next sync of flash ends well" "$(last_task sync)" "terminated 0"
check "and the new snapshot no longer has the file" test ! -e "$D/f1/.snapraid/stable/$REL"

# ---------------------------------------------------------------------------
section "a disk lost with changes not synced, rebuilt from the snapshots of the others"

sums() { (cd "$1" && find . -type f ! -name 'snapraid.*' ! -path './.snapraid/*' -print0 | sort -z | xargs -0 -r sha256sum); }
BEFORE=$(sums $D/f2)
check "f2 has files" test -n "$BEFORE"
lab scenario dead-flash-disk >/dev/null
check "f2 is empty" test -z "$(sums $D/f2)"
check "the other disks have changes not synced" sh -c "ls $D/f1/Incoming $D/f3/Incoming | grep -q new-"
req POST $AF/storage/recover '{"disks":"f2","check":true}'; is "the recovery is accepted" "$CODE" 200
check "the tasks end" tasks_wait $AF
is "the fix rebuilt everything" "$(last_task fix)" "terminated 0"
check "nothing was unrecoverable" sh -c "zcat -f \$(ls -t $LAB/log/flash/*fix* | head -1) | grep -q '^summary:error_unrecoverable:0'"
is "f2 has every file of the last sync, identical" "$(sums $D/f2)" "$BEFORE"
is "the check found no error" "$(last_task check)" "terminated 0"
is "flash: healthy" "$(health $AF)" passed

# ---------------------------------------------------------------------------
section "a hook that refuses"

lab hooks block >/dev/null
maintenance $AM; tasks_wait $AM
check "the hook was asked" grep -q " media task-begin refused" $LAB/notify/hooks.log
is "the sync was stopped before it started" "$(last_task sync)" "terminated -2"
is "the scrub after it was canceled" "$(echo "$TASKS" | jq -r '[.history[] | select(.command == "scrub")][0].status')" canceled
check "the failure was notified" sh -c "lab inbox | grep ' result ' | grep -q 'ERROR. SnapRAID Maintenance of media'"
lab hooks allow >/dev/null
maintenance $AM; tasks_wait $AM
is "with the hook allowing again, the sync ends well" "$(last_task sync)" "terminated 0"
is "media: healthy" "$(health $AM)" passed

# ---------------------------------------------------------------------------
section "disks in bad health"

lab scenario worn-flash >/dev/null
check "the wear of f1 reaches the daemon" probe_wait $AF f1 '.wear_level >= 97'
lab scenario failing-disk >/dev/null
check "the failure of p1 reaches the daemon" probe_wait $U parity '.smart.failing == true'
check "the default array is no longer healthy" test "$(health $U)" != passed
is "the other arrays are not touched" "$(health $AM)" passed
lab scenario reset-smart >/dev/null
check "p1 is good again" probe_wait $U parity '.smart.failing == false'
check "f1 is good again" probe_wait $AF f1 '.wear_level < 10'

# ---------------------------------------------------------------------------
section "the temperature limit"

if [ "${LAB_TEST_SLOW:-1}" = 1 ]; then
    lab smart d2 TEMP=58 >/dev/null
    lab churn >/dev/null
    maintenance $U
    cool=0
    for _ in $(seq 1 90); do
        get $U/activity | jq -r '.messages[]?.text' 2>/dev/null | grep -qi cooldown && { cool=1; break; }
        sleep 1
    done
    is "a sync with a disk at 58 C stops to cool down" $cool 1
    check "the hot disk is spun down" sh -c "curl -s $U/activity | jq -r '.messages[].text' | grep -q \"Spundown device .* for disk 'd2'\""
    lab smart d2 TEMP=34 >/dev/null
    check "it goes on when the disk is cool again" tasks_wait $U
    is "and the sync ends well" "$(last_task sync)" "terminated 0"
else
    skip "the temperature limit" "LAB_TEST_SLOW=0"
fi

# ---------------------------------------------------------------------------
section "the login"

DC=$LAB/etc/snapraidd.conf
CRED=$(snapraidd -g showcase:secret 2>/dev/null | grep -oE '[^ =]+:\$argon2id\$.*' | head -1)
check "a credential is generated" test -n "$CRED"
cp $DC $DC.showcase-test
sed -i "s|^net_web_root = .*|net_auth_credential = $CRED\n&|" $DC
pkill -HUP -x snapraidd; sleep 3
is "without the password the daemon answers 401" "$(curl -s -o /dev/null -w '%{http_code}' $U/state)" 401
is "with the password it answers" "$(curl -s -o /dev/null -w '%{http_code}' -u showcase:secret $U/state)" 200
# 401, or 429 when the daemon is slowing down repeated failures
check "with a wrong password it does not" sh -c "curl -s -o /dev/null -w '%{http_code}' -u showcase:wrong $U/state | grep -qE '^(401|429)\$'"
is "the metrics need no password" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7627/metrics)" 200
cp $DC.showcase-test $DC; rm -f $DC.showcase-test
pkill -HUP -x snapraidd; sleep 3
is "without the credential the lab is open again" "$(curl -s -o /dev/null -w '%{http_code}' $U/state)" 200

# ---------------------------------------------------------------------------
section "the helper"

L=$(lab disks)
is "lab disks lists every disk" "$(echo "$L" | sed 1d | wc -l)" 18
check "with the kinds" sh -c "echo '$L' | grep -E '^f1 ' | grep -q NVMe && echo '$L' | grep -E '^d3 ' | grep -q SAS && echo '$L' | grep -E '^u1 ' | grep -q USB && echo '$L' | grep -E '^d4 ' | grep -q SSD"
check "with the split parity" sh -c "echo '$L' | grep -E '^q2 ' | grep -q 'parity (split)'"
check "with the blank spares" sh -c "echo '$L' | grep -E '^s1 ' | grep -q 'blank spare'"
check "lab scenario lists the scenarios" sh -c "lab scenario | grep -q two-dead-disks"
check "lab sync asks the daemon for a sync" sh -c "lab sync media | grep -q 'media is in sync'"

# ---------------------------------------------------------------------------
section "the lab is left healthy"

tasks_wait $U; tasks_wait $AM; tasks_wait $AF
for a in $U $AM $AF; do is "the array ${a##*/} is healthy" "$(health $a)" passed; done

echo
echo "passed $PASS, failed $FAILS, skipped $SKIP"
exit $FAILS
