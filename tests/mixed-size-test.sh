#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# End to end tests of an array made of disks of different sizes: what SnapRAID promises
# ("the disks can have different sizes") and where the limits are (the parity must hold
# the fullest data disk).
#
# DESTRUCTIVE: it reformats lab disks. It runs only in a lab built for it:
#
#     docker compose -f docker-compose.sizes.yml up --build --abort-on-container-exit --exit-code-from tests
#     docker compose -f docker-compose.sizes.yml down -v
#
# Disks (MB): data d1=256 d2=512 d3=1024 d4=384, parity p1=1024 p2=1024,
#             spares s1=2048 (larger than the parity) s2=128 (tiny) s3=640 s4=640 (a split parity).

U=http://127.0.0.1:7627/snapraid/v1
S=$U/storage
M=/mnt/lab
LAB=${LAB_DIR:-/lab}
CONF=$LAB/etc/snapraid.conf
PASS=0; FAILS=0; SKIP=0
CODE=; BODY=

[ "$(cat $LAB/etc/lab-sizes 2>/dev/null)" = "d1=256 d2=512 d3=1024 d4=384 p1=1024 p2=1024 s1=2048 s2=128 s3=640 s4=640" ] \
    || { echo "refusing to run: this lab was not built by docker-compose.sizes.yml"; exit 99; }

ok()   { PASS=$((PASS + 1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; }
skip() { SKIP=$((SKIP + 1)); echo "skip  $1 ($2)"; }
section() { echo; echo "== $1"; }
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
expect() {
    if [ "$CODE" != "$2" ]; then fail "$1" "status $CODE instead of $2: $(msg)"; return 1; fi
    if [ -n "${3:-}" ] && ! msg | grep -qiE "$3"; then fail "$1" "message '$(msg)' does not match '$3'"; return 1; fi
    ok "$1"
}
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "failed: $*"; fi; }
job_wait() {
    for _ in $(seq 1 900); do
        JOB=$(curl -s $S/job | jq -c .job)
        [ "$(echo "$JOB" | jq -r .running)" = false ] && return 0
        sleep 1
    done
    return 1
}
job_ok() { job_wait && [ "$(echo "$JOB" | jq -r .success)" = true ]; }
tasks_wait() {
    sleep 2
    for _ in $(seq 1 1800); do
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
format() { # NAME FSTYPE LABEL PURPOSE -> PART UUID
    req POST $S/format "{\"device\":\"$(dev "$1")\",\"fstype\":\"$2\",\"label\":\"$3\",\"purpose\":\"$4\",\"wipe\":false}"
    [ "$CODE" = 200 ] || return 1
    job_ok || return 1
    PART=$(echo "$JOB" | jq -r .partition); UUID=$(echo "$JOB" | jq -r .uuid)
}
mount_api() { req POST $S/mount "{\"source\":\"$1\",\"target\":\"$2\",\"fstype\":\"${3:-ext4}\",\"options\":\"defaults,noatime,nofail\",\"persist\":true}"; }
sums() { (cd "$1" && find . -type f ! -name 'snapraid.*' -print0 | sort -z | xargs -0 -r sha256sum); }
fill() { # DIR MB : files of 8 MB, old enough to be moved by a balance
    mkdir -p "$1"
    for i in $(seq 1 $(( $2 / 8 ))); do head -c 8M /dev/urandom > "$1/big-$i.bin" || return 1; done
    find "$1" -type f -exec touch -d '2 hours ago' {} +
}
kb() { df -k --output="$1" "$2" | tail -1 | tr -dc 0-9; echo; }
fatals() { echo "$TASKS" | jq -r --arg c "$1" '[.history[] | select(.command == $c)][0].messages[]? | select(.level == "fatal") | .text'; }
pct() { echo $(( $(kb used "$1") * 100 / $(kb size "$1") )); }
sync_ok() { schedule '{"command":"sync"}'; tasks_wait; [ "$(last_task sync)" = "terminated 0" ]; }
recover() { # DISKS: waits for fix, check and sync
    req POST $S/recover "{\"disks\":\"$1\",\"check\":true}"
    [ "$CODE" = 200 ] || return 1
    tasks_wait
}

for _ in $(seq 1 60); do curl -s -o /dev/null $U/state && break; sleep 1; done
tasks_wait

# ---------------------------------------------------------------------------
section "an array of four different sizes"

check "the four data disks have four sizes" test "$(for d in d1 d2 d3 d4; do kb size $M/$d; done | sort -u | wc -l)" = 4
check "the parity disks are as large as the largest data disk" test "$(kb size $M/p1)" -ge "$(kb size $M/d3)"
check "the sync succeeds" sync_ok
check "the array is healthy" test "$(health)" != degraded
BIGGEST_USED=$(for d in d1 d2 d3 d4; do kb used $M/$d; done | sort -n | tail -1)
check "the parity file is as big as the fullest data disk, not as the sum" test "$(du -k $M/p1/snapraid.parity | cut -f1)" -le $(( BIGGEST_USED * 115 / 100 ))
INV=$(curl -s $S)
check "the inventory reports each disk with its own size" test "$(echo "$INV" | jq '[.mounts[] | select(.target | test("^/mnt/lab/d[1-4]$")) | .total_bytes] | unique | length')" = 4
schedule '{"command":"scrub","args":["-p","100","-o","0"]}'; tasks_wait
check "a full scrub finds no error" test "$(last_task scrub)" = "terminated 0"

# ---------------------------------------------------------------------------
section "the largest and the smallest disk die together"

W1=$(sums $M/d1); W3=$(sums $M/d3)
lab reformat d1 >/dev/null; lab reformat d3 >/dev/null
schedule '{"command":"probe"}'; tasks_wait
check "the array is degraded" test "$(health)" = degraded
check "the recovery of both runs" recover "d1,d3"
check "fix succeeded" test "$(last_task fix)" = "terminated 0"
check "the smallest disk is back, file by file" test "$(sums $M/d1)" = "$W1"
check "the largest disk is back, file by file" test "$(sums $M/d3)" = "$W3"
check "nothing was unrecoverable" test -z "$(find $M/d1 $M/d3 -name '*.unrecoverable')"
check "the array is no more degraded" test "$(health)" != degraded

# ---------------------------------------------------------------------------
section "a split parity made of two small disks"

# 2-parity moves from one 1024 MB disk to two of 640 MB
check "the first half is formatted for parity" format s3 ext4 parity2a parity
U3=$UUID
check "the second half is formatted for parity" format s4 ext4 parity2b parity
U4=$UUID
mount_api "UUID=$U3" $M/p2a; expect "the first half is mounted" 200
mount_api "UUID=$U4" $M/p2b; expect "the second half is mounted" 200
check "each half is smaller than the largest data disk" test "$(kb size $M/p2a)" -lt "$(kb size $M/d3)"
check "together they are larger" test $(( $(kb size $M/p2a) + $(kb size $M/p2b) )) -gt "$(kb size $M/d3)"
NEWCONF=$(sed "s|^2-parity .*|2-parity $M/p2a/snapraid.2-parity,$M/p2b/snapraid.2-parity|" $CONF)
req PUT $S/engine_conf "$(jq -n --arg t "$NEWCONF" '{text: $t}')"; expect "the configuration with the split parity is accepted" 200
check "the split parity is rebuilt" recover "2-parity"
check "its fix succeeded" test "$(last_task fix)" = "terminated 0"
check "the second file of the split parity is not reported as an error" test -z "$(fatals fix)"

# the largest data disk grows beyond what one half can hold
fill $M/d3/Grow 480
check "the largest data disk now holds more than one half of the parity" test "$(kb used $M/d3)" -gt "$(kb size $M/p2a)"
check "the sync succeeds" sync_ok
check "the parity went over to the second half" test "$(du -k $M/p2b/snapraid.2-parity | cut -f1)" -gt 1000
check "the first half is full" test "$(kb avail $M/p2a)" -lt 20000

# two disks lost: the second can only come back from the split parity
W2=$(sums $M/d2); W3=$(sums $M/d3)
lab reformat d2 >/dev/null; lab reformat d3 >/dev/null
schedule '{"command":"probe"}'; tasks_wait
check "two disks are recovered using the split parity" recover "d2,d3"
check "fix succeeded" test "$(last_task fix)" = "terminated 0"
check "d2 is back, file by file" test "$(sums $M/d2)" = "$W2"
check "d3 is back, file by file, the part in the second half included" test "$(sums $M/d3)" = "$W3"
check "nothing was unrecoverable" test -z "$(find $M/d2 $M/d3 -name '*.unrecoverable')"

# ---------------------------------------------------------------------------
section "a pool of disks of different sizes"

POOL=/mnt/storage
OPTS="cache.files=off,category.create=pfrd,func.getattr=newest,dropcacheonclose=false,minfreespace=10M,moveonenospc=true,fsname=mergerfs,allow_other"
req POST $S/pool "{\"mountpoint\":\"$POOL\",\"branches\":\"$M/d1:$M/d2:$M/d3:$M/d4\",\"options\":\"$OPTS\",\"persist\":true}"
expect "the pool is created" 200
SUM=$(( $(kb size $M/d1) + $(kb size $M/d2) + $(kb size $M/d3) + $(kb size $M/d4) ))
check "the pool is as large as the sum of its disks" test "$(kb size $POOL)" = "$SUM"

# the smallest disk nearly full, the others as they are
rm -rf $M/d3/Grow; fill $M/d1/Bulk $(( $(kb avail $M/d1) / 1024 - 24 ))
BEFORE=$( (for d in d1 d2 d3 d4; do sums $M/$d; done) | sort)
P1=$(pct $M/d1)
check "the small disk is the fullest (${P1}%)" test "$P1" -gt 80
req POST $S/balance "{\"mountpoint\":\"$POOL\",\"max_bytes\":\"4000000000\",\"spread\":\"5\"}"; expect "the balance starts" 200
job_wait
check "the balance completes" test "$(echo "$JOB" | jq -r '.kind + " " + (.success | tostring)')" = "balance true"
PCTS=$(for d in d1 d2 d3 d4; do pct $M/$d; done | sort -n)
SPREAD=$(( $(echo "$PCTS" | tail -1) - $(echo "$PCTS" | head -1) ))
check "the disks end at the same fill level, within 12 points (now $SPREAD)" test "$SPREAD" -le 12
check "so the large disk holds more data than the small one" test "$(kb used $M/d3)" -gt "$(kb used $M/d1)"
check "no disk was filled to the brim" test "$(for d in d1 d2 d3 d4; do kb avail $M/$d; done | sort -n | head -1)" -gt 10240
check "every file has the same content as before" test "$( (for d in d1 d2 d3 d4; do sums $M/$d; done) | sort)" = "$BEFORE"
check "the sync after the balance succeeds" sync_ok

# a file larger than the free space of the small disks goes to a disk that has room
SMALLFREE=$(kb avail $M/d1)
head -c $(( SMALLFREE + 20480 ))K /dev/urandom > $POOL/larger-than-the-small-disk.bin
check "a file that does not fit the small disk is written through the pool" test -s $POOL/larger-than-the-small-disk.bin
rm -f $POOL/larger-than-the-small-disk.bin

# ---------------------------------------------------------------------------
section "a data disk replaced by one larger than the parity"

req POST $S/unmount "{\"target\":\"$POOL\",\"forget\":false}"
W1=$(sums $M/d1)
req POST $S/unmount "{\"target\":\"$M/d1\",\"forget\":true}"; expect "the old small disk is unmounted" 200
check "the new disk is formatted" format s1 ext4 d1 data
mount_api "UUID=$UUID" $M/d1; expect "and mounted in its place" 200
check "the new data disk is larger than the parity" test "$(kb size $M/d1)" -gt "$(kb size $M/p1)"
check "its content is rebuilt" recover "d1"
check "fix succeeded" test "$(last_task fix)" = "terminated 0"
check "every file is back with the same content" test "$(sums $M/d1)" = "$W1"
check "the sync succeeds while the data fits the parity" sync_ok

# now the disk is filled beyond the parity
STABLE=$(sums $M/d2)
fill $M/d1/Overflow $(( $(kb size $M/p1) / 1024 + 80 - $(kb used $M/d1) / 1024 ))
check "the data disk holds more than the parity disk can" test "$(kb used $M/d1)" -gt "$(kb size $M/p1)"
schedule '{"command":"sync"}'; tasks_wait
check "the sync fails instead of leaving a short parity" test "$(last_task sync | cut -d' ' -f1)" != "terminated" -o "$(last_task sync | cut -d' ' -f2)" != 0
check "the reason given is the parity space" sh -c 'echo "$0" | grep -q "Insufficient parity space"' "$(fatals sync)"
check "and the files that did not fit are listed" test "$(fatals sync | grep -c '^outofparity /mnt/lab/d1/Overflow/')" -gt 0

# what was protected before is still protected
lab reformat d2 >/dev/null
schedule '{"command":"probe"}'; tasks_wait
check "another disk can still be recovered after the failed sync" recover "d2"
check "with every file intact" test "$(sums $M/d2)" = "$STABLE"

check "its files are verified" test "$(last_task check)" = "terminated 0"
check "but the closing sync stops again on the parity space" test "$(last_task sync)" = "terminated 1"

# the way out: bring the data back under the size of the parity, then let the array take the disks as they are
rm -rf $M/d1/Overflow
req POST $S/recover '{"disks":"","check":false,"accept":true}'; expect "after freeing space the array is brought back" 200
tasks_wait
check "the sync succeeds" test "$(last_task sync)" = "terminated 0"
check "the array is no more degraded" test "$(health)" != degraded
check "normal syncs work again" sync_ok
check "a successful sync reports no error" test -z "$(fatals sync)"

# ---------------------------------------------------------------------------
section "a tiny disk"

check "a 128 MB disk is formatted for data" format s2 ext4 tiny data
mount_api "UUID=$UUID" $M/tiny; expect "and mounted" 200
req POST $S/unmount "{\"target\":\"$M/tiny\",\"forget\":true}"
req POST $S/format "{\"device\":\"$(dev s2)\",\"fstype\":\"ext4\",\"label\":\"tinypar\",\"purpose\":\"parity\",\"wipe\":true}"
check "and for parity" job_ok

echo
echo "passed $PASS, failed $FAILS, skipped $SKIP"
exit $FAILS
