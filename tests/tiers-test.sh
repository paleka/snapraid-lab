#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Checks the moves of files among the disks of a pool (a folder to a chosen disk, a disk emptied,
# a fast disk in front of the pool with its mover), the move of the parity to a larger disk, the
# size of a folder disk by disk, the reading test of a disk, the copy of a single file, and the
# sync that goes on after a big tidy up.
#
# It works on the showcase lab of docker-compose.yml as it is after the first start. It formats
# the blank disks s1 (the new parity) and s2 (the fast disk) and writes on u1:
#
#     docker compose -f docker-compose.tiers.yml up --build --abort-on-container-exit --exit-code-from tests
#
# LAB_TEST_SLOW=0 skips the sync run again by the daemon, which waits a minute and a half.
# Every test prints "ok" or "FAIL" with the reason; the exit code is the number of failures.

U=http://127.0.0.1:7627/snapraid/v1
H=$U/host
S=$U/storage
LAB=${LAB_DIR:-/lab}
D=/mnt/lab
POOL=/mnt/storage
PASS=0; FAILS=0; SKIP=0
CODE=; BODY=

[ "$(cat $LAB/etc/lab-preset 2>/dev/null)" = ready ] || { echo "refusing to run: this lab was not started with LAB_PRESET=ready"; exit 99; }
for d in d1 d2 d3 d4 p1 s1 s2 u1; do grep -qx "$d" $LAB/etc/lab-disks || { echo "refusing to run: the lab has no disk $d"; exit 99; }; done

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
msg() { echo "$BODY" | jq -r '.message // empty' 2>/dev/null; }
expect() { # NAME CODE [REGEX on the message]
    if [ "$CODE" != "$2" ]; then fail "$1" "status $CODE instead of $2: $(msg)"; return 1; fi
    if [ -n "${3:-}" ] && ! msg | grep -qiE "$3"; then fail "$1" "message '$(msg)' does not match '$3'"; return 1; fi
    ok "$1"
}
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "failed: $*"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then fail "$name" "unexpectedly true: $*"; else ok "$name"; fi; }
post() { req POST "$H/$1" "$2"; }
spost() { req POST "$S/$1" "$2"; }
host() { curl -s $H | jq -r "$1"; }
job_wait() {
    for _ in $(seq 1 900); do
        JOB=$(curl -s $S/job | jq -c .job)
        [ "$(echo "$JOB" | jq -r .running)" = false ] && return 0
        sleep 1
    done
    return 1
}
job_ok() { job_wait && [ "$(echo "$JOB" | jq -r .success)" = true ]; }
jobf() { echo "$JOB" | jq -r "$1"; }
tasks_wait() { # until the array has nothing running or queued
    sleep 2
    for _ in $(seq 1 600); do
        [ "$(curl -s "$U/tasks?limit_history=0&limit_messages=0" | jq '(.active | length) + (.pending | length)')" = 0 ] && return 0
        sleep 1
    done
    return 1
}
last_task() { curl -s "$U/tasks?limit_history=12&limit_messages=0" | jq -r "[.history[] | select(.command == \"$1\")][0] | $2"; }
disk_dev() { # the whole loop device of a disk of the lab, mounted or not
    local loop
    for f in /run/lab/map/*; do [ "$(cat "$f")" = "$1" ] && loop=$(basename "$f"); done
    echo "/dev/$loop"
}
# the content of the pool as its users see it: names and data of every file
pool_sum() { (cd $POOL && find . -type f ! -name 'snapraid.content*' -print0 | sort -z | xargs -0 md5sum | md5sum | cut -d' ' -f1); }
files_in() { find "$1" -type f ! -name 'snapraid.content*' 2>/dev/null | wc -l; }

tasks_wait
# a file changed in the last five minutes is never moved, and the lab has just written some:
# they are made older, the files left for being young are tried on their own below
find $D/d1 $D/d2 $D/d3 $D/d4 -type f -mmin -60 ! -name 'snapraid.content*' -exec touch -d '2 hours ago' {} +
SUM=$(pool_sum)

section "a folder to a chosen disk"
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/zz\",\"kind\":\"move\"}";                       expect "a disk that is not of the pool is refused" 400 "not a disk of the pool"
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d1\",\"to\":\"$D/d1\",\"kind\":\"move\"}";        expect "the same disk as destination is refused" 400 "already on"
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d2\",\"to\":\"$D/u1\",\"kind\":\"move\"}";        expect "a destination outside the pool is refused" 400 "not a disk of the pool"
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d2\",\"path\":\"/../etc\",\"kind\":\"move\"}";    expect "a path climbing out is refused" 400 "invalid folder"
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d2\",\"path\":\"/NoSuchFolder\",\"to\":\"$D/d1\",\"kind\":\"move\"}"; expect "a missing folder is refused" 404 "not on that disk"
spost move "{\"mountpoint\":\"/mnt/nopool\",\"from\":\"$D/d2\",\"kind\":\"move\"}";                 expect "a pool that is not there is refused" 400 "not a mounted mergerfs pool"
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d2\",\"kind\":\"shuffle\"}";                     expect "an unknown kind is refused" 400 "unknown kind"
# a link inside a disk leading out of it: the files behind it are not of the pool
mkdir -p /tmp/lab-outside/sub $D/d2/Linked && echo keep > /tmp/lab-outside/sub/file.txt && ln -sfn /tmp/lab-outside $D/d2/Linked/out
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d2\",\"path\":\"/Linked/out\",\"to\":\"$D/d1\",\"kind\":\"move\"}";     expect "a link in place of the folder is refused" 404 "not on that disk"
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d2\",\"path\":\"/Linked/out/sub\",\"to\":\"$D/d1\",\"kind\":\"move\"}"; expect "a folder behind a link leading out is refused" 400 "link leading out"
check "and what is behind the link is untouched" test "$(cat /tmp/lab-outside/sub/file.txt)" = keep
rm -rf $D/d2/Linked /tmp/lab-outside
BEFORE=$(files_in $POOL/Photos)
check "the folder is spread over more disks" test "$(files_in $D/d2/Photos)" -gt 0 -a "$(files_in $D/d3/Photos)" -gt 0
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d2:$D/d3:$D/d4\",\"path\":\"/Photos\",\"to\":\"$D/d1\",\"kind\":\"move\"}"
expect "the move of a folder starts" 200
check "and ends well" job_ok
check "every file of the folder is on the chosen disk" test "$(files_in $D/d1/Photos)" = "$BEFORE"
check "none is left on the other disks" test "$(files_in $D/d2/Photos)$(files_in $D/d3/Photos)$(files_in $D/d4/Photos)" = 000
check "the folders left empty are gone" test ! -d $D/d2/Photos
check "the pool shows the same files with the same data" test "$(pool_sum)" = "$SUM"
check "the other folders did not move" test "$(files_in $D/d2/Movies)" -gt 0

section "a disk emptied"
# the lab has three files with the same name on d1 and d3: which one is good is not for the daemon to say
DUPS=$(cd $D/d1 && find . -type f ! -name 'snapraid.content*' | while read -r f; do for o in d2 d3 d4; do [ -e "$D/$o/$f" ] && echo "$f"; done; done | sort -u | wc -l)
HAD=$(files_in $D/d1)
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/d1\",\"kind\":\"empty\"}"
expect "the emptying of a disk starts" 200
check "and ends well" job_ok
check "only the files with a twin on another disk are left" test "$(files_in $D/d1)" = "$DUPS"
check "they are counted and named" test "$(jobf .skipped)" = "$DUPS" -a "$(jobf '.result | length')" = "$DUPS"
check "the others were moved" test "$(jobf .files)" = "$((HAD - DUPS))"
check "the content file of the array stays on the disk" test -f $D/d1/snapraid.content
check "the pool shows the same files with the same data" test "$(pool_sum)" = "$SUM"
# a disk left without the files it had makes the sync stop and ask, as for a disk not mounted
req POST $U/schedule '{"tasks":[{"command":"sync"}]}'
tasks_wait
check "a plain sync stops for the emptied disk" test "$(last_task sync .exit_code)" != 0
req POST $U/schedule '{"tasks":[{"command":"sync","args":["-E"]}]}'
tasks_wait
check "told that it was on purpose, the array takes the moved files" test "$(last_task sync .exit_code)" = 0

section "size of a folder, disk by disk"
post usage '{"path":"/etc"}';                    expect "a system folder is refused" 400 "system folder"
post usage "{\"path\":\"$POOL/NoSuchFolder\"}";  expect "a missing folder is refused" 404 "does not exist"
post usage "{\"path\":\"$POOL/Movies\"}";        expect "the count starts" 202
check "and ends well" job_ok
check "every disk holding the folder has its line" test "$(jobf '.result | length')" = "$(for d in d1 d2 d3 d4; do [ "$(files_in $D/$d/Movies)" -gt 0 ] && echo $d; done | wc -l)"
check "the files add up" test "$(jobf '[.result[].value | split(" ")[1] | tonumber] | add')" = "$(files_in $POOL/Movies)"
post usage "{\"path\":\"$D/u1\"}"
check "a folder outside the pools is counted as one" job_ok
check "with one line" test "$(jobf '.result | length')" = 1

section "reading test of a disk"
U1=$(disk_dev u1)
post surface "{\"device\":\"${U1}p1\"}";  expect "a partition is refused" 400 "not a whole disk"
post surface '{"device":"/dev/null"}';   expect "what is not a disk is refused" 400 "not a whole disk"
post surface "{\"device\":\"$U1\"}";      expect "the reading of a disk in use starts" 202
check "and every block is read" job_ok
check "the whole size was read" test "$(jobf .bytes)" = "$(blockdev --getsize64 "$U1")"

section "copy of a single file"
F=$(find $POOL/Documents -type f | head -1)
post copy "{\"source\":\"$F\",\"target\":\"$D/u1/Copies\",\"mirror\":true}";  expect "a single file cannot be mirrored" 400 "only a folder"
post copy "{\"source\":\"$F\",\"target\":\"$D/u1/Copies\"}";                  expect "the copy of a file starts" 202
check "and ends well" job_ok
check "the file is in the folder, with the same data" cmp "$F" "$D/u1/Copies/$(basename "$F")"

section "a fast disk in front of the pool"
S2=$(disk_dev s2)
spost format "{\"device\":\"$S2\",\"fstype\":\"ext4\",\"label\":\"cache\",\"purpose\":\"data\",\"wipe\":false}"
expect "the fast disk is formatted" 200
check "format done" job_ok
CU=$(jobf .uuid)
spost mount "{\"source\":\"UUID=$CU\",\"target\":\"$D/cache\",\"fstype\":\"ext4\",\"options\":\"defaults,noatime,nofail\",\"persist\":true}"
expect "and mounted" 200
CACHE="{\"name\":\"cache\",\"pool\":\"$POOL\",\"branch\":\"$D/cache\",\"age_hours\":\"0\",\"fill\":\"70\",\"when\":\"03:00\",\"sync\":true,\"enabled\":true,\"policy\":\"pfrd\"}"
post cache_save "$CACHE";                                                             expect "a disk not yet in the pool is refused" 400 "not a disk of the pool"
OPTS=$(curl -s $S | jq -r ".pools[] | select(.mountpoint == \"$POOL\") | .fstab_options" | sed 's/category.create=[a-z]*/category.create=ff/')
spost pool "{\"mountpoint\":\"$POOL\",\"branches\":\"$D/cache:$D/d1:$D/d2:$D/d3:$D/d4\",\"options\":\"$OPTS\",\"persist\":true}"
expect "it goes first in the pool" 200
post cache_save "{\"name\":\"bad name\",\"pool\":\"$POOL\",\"branch\":\"$D/cache\"}";  expect "a wrong name is refused" 400 "letters"
post cache_save "{\"name\":\"cache\",\"pool\":\"$POOL\",\"branch\":\"$D/d1\"}";        expect "a disk of the array is refused" 409 "disk d1 of the array"
post cache_save "{\"name\":\"cache\",\"pool\":\"/mnt/nopool\",\"branch\":\"$D/cache\"}"; expect "a pool that is not there is refused" 400 "not a mounted mergerfs pool"
post cache_save "{\"name\":\"cache\",\"pool\":\"$POOL\",\"branch\":\"$D/cache\",\"fill\":\"100\"}"; expect "a fill level of 100 is refused" 400 "0 to 99"
post settings '{"cache.x":"pool=/mnt/x"}';                                             expect "fast disks have their own request" 400 "of its own"
post cache_save "$CACHE";                                                             expect "the fast disk is saved" 202
check "it is read back with its options" test "$(host '.caches[0] | .name + " " + .when + " " + (.fill | tostring) + " " + (.sync | tostring)')" = "cache 03:00 70 true"
check "and with its space" test "$(host '.caches[0].total_bytes')" -gt 1000000
post cache_run '{"name":"nothere"}';                                                  expect "a fast disk that is not there cannot run" 404 "no fast disk"

mkdir -p $POOL/Incoming/fresh
for i in 1 2 3; do head -c 2000000 /dev/urandom > $POOL/Incoming/fresh/new-$i.bin; done
head -c 5000 /dev/urandom > $POOL/Photos/new-photo.jpg
check "new files of the pool land on the fast disk" test "$(files_in $D/cache)" = 4
check "the daemon counts what waits on it" test "$(host '.caches[0] | (.waiting_files | tostring) + " " + (.waiting_more | tostring)')" = "4 false"
check "with its size" test "$(host '.caches[0].waiting_bytes')" -ge 6000000
check "and the pool shows them" test "$(files_in $POOL/Incoming/fresh)" = 3
NEWSUM=$(pool_sum)
# the mover never takes a file written in the last minutes: here they are made older
find $D/cache -type f -exec touch -d '20 minutes ago' {} +
post cache_run '{"name":"cache"}';  expect "the mover starts" 202
check "and ends well" job_ok
check "it moved the four files" test "$(jobf .files)" = 4
check "the fast disk is empty, folders included" test "$(find $D/cache -mindepth 1 ! -name 'lost+found' | wc -l)" = 0
check "the files are on the disks of the array" test "$(for d in d1 d2 d3 d4; do files_in $D/$d/Incoming/fresh; done | awk '{ n += $1 } END { print n }')" = 3
check "the pool shows the same files with the same data" test "$(pool_sum)" = "$NEWSUM"
check "the result is kept" test "$(host '.caches[0] | (.last_status | tostring) + " " + .last_message')" = "0 4 files moved"
check "nothing waits on it any more" test "$(host '.caches[0].waiting_files')" = 0
tasks_wait
check "the protection was updated right after" test "$(last_task sync .exit_code)" = 0
check "the array is healthy" test "$(curl -s $U/array | jq -r .health)" = passed

head -c 100000 /dev/urandom > $POOL/Incoming/fresh/just-written.bin
post cache_run '{"name":"cache"}'
check "a file just written is left for the next time" job_ok
check "nothing was moved" test "$(jobf .files)" = 0 -a -f $D/cache/Incoming/fresh/just-written.bin
check "and the mover does not list it as a problem" test "$(jobf .skipped)" = 0
# who empties a disk is told about it instead
spost move "{\"mountpoint\":\"$POOL\",\"from\":\"$D/cache\",\"kind\":\"empty\"}"
check "emptying the fast disk by hand leaves the file just written too" job_ok
check "and names it with the reason" test "$(jobf '.skipped | tostring')$(jobf '.result[0].value' | grep -c 'last minutes')" = 11

post cache_delete '{"name":"cache"}';  expect "the fast disk is forgotten" 202
check "it is out of the settings" test "$(host '.caches | length')" = 0
refute "with its last result" grep -q 'cache\.cache' "$(host .settings_file)"
post cache_save "$CACHE"

section "the parity on a larger disk"
S1=$(disk_dev s1)
OLD=$D/p1/snapraid.parity
spost parity_move "{\"parity\":\"parity\",\"target\":\"$D/nowhere\"}";  expect "a folder that is not a mount is refused" 400 "not the mount point"
spost parity_move "{\"parity\":\"3-parity\",\"target\":\"$D/u1\"}";      expect "a level the array does not have is refused" 404 "no 3-parity"
spost parity_move "{\"parity\":\"sync\",\"target\":\"$D/u1\"}";          expect "what is not a parity level is refused" 400 "unknown parity"
spost parity_move "{\"parity\":\"parity\",\"target\":\"$D/x1\"}";        expect "a disk without room is refused" 409 "too small"
spost parity_move "{\"parity\":\"parity\",\"target\":\"$POOL\"}";        expect "a pool is refused" 400 "not the mount point"
req POST $U/arrays/media/storage/parity_move "{\"parity\":\"parity\",\"target\":\"$D/u1\"}"
expect "a split parity is refused, with what to do" 409 "split"
spost format "{\"device\":\"$S1\",\"fstype\":\"ext4\",\"label\":\"parity1\",\"purpose\":\"parity\",\"wipe\":false}"
expect "the new parity disk is formatted" 200
check "format done" job_ok
PU=$(jobf .uuid)
spost mount "{\"source\":\"UUID=$PU\",\"target\":\"$D/p1-2\",\"fstype\":\"ext4\",\"options\":\"defaults,noatime,nofail\",\"persist\":true}"
expect "and mounted" 200
OLDSUM=$(md5sum < $OLD)
spost parity_move "{\"parity\":\"parity\",\"target\":\"$D/p1-2\"}"
expect "the copy of the parity starts" 200
check "and ends well" job_ok
check "the copy is the same as the original" test "$(md5sum < $D/p1-2/snapraid.parity)" = "$OLDSUM"
check "the old parity was not touched" test "$(md5sum < $OLD)" = "$OLDSUM"
check "the array now uses the new file" grep -qx "parity $D/p1-2/snapraid.parity" $LAB/etc/snapraid.conf
check "the other level is as before" grep -qx "2-parity $D/p2/snapraid.2-parity" $LAB/etc/snapraid.conf
check "the previous configuration is kept" test -f $LAB/etc/snapraid.conf.snapraidd.bak
spost parity_move "{\"parity\":\"parity\",\"target\":\"$D/p1-2\"}";      expect "a second copy over the first is refused" 409 "already"
# for the array the parity is on a changed disk: it's told that nothing was lost
spost recover '{"disks":"","check":false,"accept":true,"force_uuid":false}'
expect "the array records the new parity disk" 200
tasks_wait
check "with a sync that ends well" test "$(last_task sync .exit_code)" = 0
check "the array is healthy" test "$(curl -s $U/array | jq -r .health)" = passed
req POST $U/schedule '{"tasks":[{"command":"scrub","args":["-p","100","-o","0"]}]}'
tasks_wait
check "every block checks against the copied parity" test "$(last_task scrub '(.exit_code | tostring) + " " + ((.error_data // 0) | tostring) + " " + ((.error_io // 0) | tostring)')" = "0 0 0"
# the proof that the new parity works: a file deleted is rebuilt from it
V=$(find $D/d3/Movies -type f | head -1)
VSUM=$(md5sum < "$V")
rm -f "$V"
req POST $U/schedule "{\"tasks\":[{\"command\":\"fix\",\"args\":[\"-m\",\"-d\",\"d3\"]}]}"
tasks_wait
check "a deleted file is rebuilt with the new parity" test "$(md5sum < "$V" 2>/dev/null)" = "$VSUM"

section "a sync that goes on after a big tidy up"
post settings '{"sync_ratio":"x"}';     expect "a ratio that is not a number is refused" 400 "0 to 1000"
post settings '{"sync_ratio":"2"}';     expect "the ratio is saved" 202
check "and read back" test "$(host .settings.sync_ratio)" = 2
if [ "${LAB_TEST_SLOW:-1}" = 1 ]; then
    req PATCH $U/config '{"sync_threshold_deletes":5}'
    # eight files deleted and twenty added, straight on a disk of the array
    find $D/d2/Music $D/d3/Music $D/d4/Music -type f 2>/dev/null | head -8 | xargs rm -f
    mkdir -p $D/d3/Incoming/tidy
    for i in $(seq 1 20); do head -c 20000 /dev/urandom > $D/d3/Incoming/tidy/t$i.bin; done
    req POST $U/maintenance '{}'
    tasks_wait
    check "the sync stops for the deleted files" test "$(last_task sync .exit_code)" = 2
    FIRST=$(last_task sync .number)
    # the daemon looks once a minute
    for _ in $(seq 1 100); do [ "$(last_task sync .number)" != "$FIRST" ] && break; sleep 1; done
    tasks_wait
    check "the daemon runs it again by itself" test "$(last_task sync .number)" != "$FIRST"
    check "and this time it ends well" test "$(last_task sync .exit_code)" = 0

    # with fewer files added than the ratio asks, it keeps waiting for the person
    find $D/d2/Movies $D/d3/Movies $D/d4/Movies -type f 2>/dev/null | head -8 | xargs rm -f
    for i in $(seq 1 4); do head -c 20000 /dev/urandom > $D/d3/Incoming/tidy/u$i.bin; done
    req POST $U/maintenance '{}'
    tasks_wait
    SECOND=$(last_task sync .number)
    check "a sync with few files added stops too" test "$(last_task sync .exit_code)" = 2
    sleep 75
    tasks_wait
    check "and it is not run again" test "$(last_task sync .number)" = "$SECOND"
    req POST $U/schedule '{"tasks":[{"command":"sync"}]}'
    tasks_wait
    req PATCH $U/config '{"sync_threshold_deletes":0}'
else
    skip "the sync run again by the daemon" "LAB_TEST_SLOW=0"
fi
post settings '{"sync_ratio":""}'

section "the lab as it was"
req POST $U/refresh '{}'
for _ in $(seq 1 90); do
    [ "$(curl -s $U/arrays | jq -r '[.arrays[] | select(.health != "passed")] | length')" = 0 ] && break
    sleep 1
done
check "every array is healthy after the tests" test "$(curl -s $U/arrays | jq -r '[.arrays[] | select(.health != "passed")] | length')" = 0

echo
echo "tiers tests: $PASS ok, $FAILS failed, $SKIP skipped"
exit $FAILS
