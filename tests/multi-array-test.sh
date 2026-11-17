#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# End to end tests of more than one array in the same daemon: the arrays API, an array of its
# own for every SnapRAID configuration, the arbiter, pools and mounts with their protection.
#
# DESTRUCTIVE: it formats the lab disks. It runs only in a lab started with LAB_PRESET=blank
# and at least 5 data disks, 2 parity disks and 1 spare:
#
#     docker compose -f docker-compose.arrays.yml up --build --abort-on-container-exit
#
# Every test prints "ok" or "FAIL" with the reason; the exit code is the number of failures.

U=http://127.0.0.1:7627/snapraid/v1
V2=http://127.0.0.1:7627/snapraid/v2
S=$U/storage
M=$U/arrays/media
T=${LAB_TEST_DIR:-/mnt/t}
LAB=${LAB_DIR:-/lab}
PASS=0; FAILS=0; SKIP=0
CODE=; BODY=

[ "$(cat $LAB/etc/lab-preset 2>/dev/null)" = blank ] || { echo "refusing to run: this lab was not started with LAB_PRESET=blank"; exit 99; }
[ -z "$(ls -A $T 2>/dev/null)" ] || { echo "refusing to run: $T is not empty, start from a new lab (docker compose down -v)"; exit 99; }
for d in d1 d2 d3 d4 d5 p1 p2 s1; do grep -qx "$d" $LAB/etc/lab-disks || { echo "refusing to run: the lab has no disk $d"; exit 99; }; done

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
expect() { # NAME CODE [REGEX on the message]
    if [ "$CODE" != "$2" ]; then fail "$1" "status $CODE instead of $2: $(msg)"; return 1; fi
    if [ -n "${3:-}" ] && ! msg | grep -qiE "$3"; then fail "$1" "message '$(msg)' does not match '$3'"; return 1; fi
    ok "$1"
}
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "failed: $*"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then fail "$name" "unexpectedly true: $*"; else ok "$name"; fi; }
get() { curl -s -m 60 "$1"; }

job_wait() {
    for _ in $(seq 1 900); do
        JOB=$(get $S/job | jq -c .job)
        [ "$(echo "$JOB" | jq -r .running)" = false ] && return 0
        sleep 1
    done
    return 1
}
job_ok() { job_wait && [ "$(echo "$JOB" | jq -r .success)" = true ]; }
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
count_task() { get "$1/tasks" | jq --arg c "$2" '[.history[] | select(.command == $c)] | length'; }
schedule() { req POST "$1/schedule" "{\"tasks\":[$2]}"; }
health() { get "$1/state" | jq -r .health; }
dev() { basename "$(grep -lx "$1" /run/lab/map/* | head -1)" | sed 's|^|/dev/|'; }
format() { # NAME LABEL PURPOSE -> PART UUID
    req POST $S/format "{\"device\":\"$(dev "$1")\",\"fstype\":\"ext4\",\"label\":\"$2\",\"purpose\":\"$3\",\"wipe\":false}"
    [ "$CODE" = 200 ] || return 1
    job_ok || return 1
    PART=$(echo "$JOB" | jq -r .partition); UUID=$(echo "$JOB" | jq -r .uuid)
}
mount_api() { req POST $S/mount "{\"source\":\"$1\",\"target\":\"$2\",\"fstype\":\"ext4\",\"options\":\"${3:-defaults,noatime,nofail}\",\"persist\":true}"; }
disk() { # NAME PURPOSE: format and mount at $T/NAME
    format "$1" "$1" "$2" || { fail "disk $1 is prepared" "$(msg)"; return 1; }
    eval "U_$1=$UUID; P_$1=$PART"
    mount_api "UUID=$UUID" "$T/$1"
    [ "$CODE" = 200 ] || { fail "disk $1 is prepared" "$(msg)"; return 1; }
}
sums() { (cd "$1" && find . -type f ! -name 'snapraid.*' -print0 | sort -z | xargs -0 -r sha256sum); }
fill() { # DIR COUNT KB
    mkdir -p "$1"
    for i in $(seq 1 "$2"); do head -c "${3}K" /dev/urandom > "$1/file-$i.bin"; done
    find "$1" -type f -exec touch -d '2 hours ago' {} +
}
conf() { # BASE TEXT
    req PUT "$1/storage/engine_conf" "{\"text\":\"$2\"}"
}
pool() { req POST $S/pool "{\"mountpoint\":\"$1\",\"branches\":\"$2\",\"options\":\"cache.files=off,category.create=pfrd,minfreespace=10M,fsname=mergerfs,allow_other\",\"persist\":true}"; }
start_of() { echo "$TASKS" | jq -r --arg c "$1" '[.history[] | select(.command == $c)][0].started_at'; }
end_of()   { echo "$TASKS" | jq -r --arg c "$1" '[.history[] | select(.command == $c)][0].finished_at'; }
epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

for _ in $(seq 1 60); do curl -s -o /dev/null $U/state && break; sleep 1; done

DCONF=$LAB/etc/snapraidd.conf
ADIR=$LAB/etc/snapraidd.d
MCONF=$LAB/etc/snapraid/media.conf

# ---------------------------------------------------------------------------
section "one array, as it always was"

req GET $U/arrays;                                expect "the arrays are listed" 200
check "there is only the default array" test "$(echo "$BODY" | jq -r '[.arrays[].name] | join(",")')" = default
check "it is marked as the default" test "$(echo "$BODY" | jq -r '.arrays[0].default')" = true
check "the arrays directory is next to the main configuration" test "$(echo "$BODY" | jq -r .arrays_dir)" = "$ADIR"
check "arrays run one at a time unless told otherwise" test "$(echo "$BODY" | jq -r .array_parallel)" = false
check "the state names its array" test "$(get $U/state | jq -r '.array + " " + (.arrays_count | tostring)')" = "default 1"
req GET $U/arrays/default/state;                  expect "the default array is reachable by name" 200
req GET $U/arrays/default;                        expect "and has a summary" 200
check "not yet configured" test "$(echo "$BODY" | jq -r .configured)" = false

for d in d1 d2; do disk $d data; done
disk p1 parity
D="# default array\nparity $T/p1/snapraid.parity\ncontent $LAB/etc/snapraid.content\ncontent $T/d1/snapraid.content\ndata d1 $T/d1\ndata d2 $T/d2\nexclude /lost+found/\n"
conf $U "$D";                                     expect "the default array is configured" 200
fill $T/d1/Movies 6 3000; fill $T/d2/Photos 20 150
schedule $U '{"command":"probe"},{"command":"sync"}'; tasks_wait $U
check "the first sync of the default array succeeds" test "$(last_task sync)" = "terminated 0"

# ---------------------------------------------------------------------------
section "creating an array"

req POST $U/arrays '{"name":"Media"}';            expect "uppercase names are refused" 400 "name"
req POST $U/arrays '{"name":"me dia"}';           expect "names with spaces are refused" 400
req POST $U/arrays '{"name":"../etc"}';           expect "names with slashes are refused" 400
req POST $U/arrays '{"name":"-x"}';               expect "names starting with a dash are refused" 400
req POST $U/arrays '{"name":"abcdefghijklmnopqrstuvwxyz0123456"}'; expect "names over 31 characters are refused" 400
req POST $U/arrays '{"name":"default"}';          expect "the default array cannot be created again" 409 "always exists"
req POST $U/arrays '{}';                          expect "a name is required" 400 "name"
req POST $U/arrays '{"name":"media","extra":1}';  expect "unknown fields are refused" 400
req POST $U/arrays '{"name":"media","engine_conf":"relative.conf"}'; expect "a relative configuration path is refused" 400
req POST $U/arrays '{"name":"media","engine_conf":"/etc/../x.conf"}'; expect "a configuration path with .. is refused" 400
req POST $U/arrays "{\"name\":\"media\",\"engine_conf\":\"$LAB/etc/snapraid.conf\"}"
expect "the configuration of another array is refused" 409 "already the SnapRAID configuration"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data '{"name":"media"}' $U/arrays)
check "a request without the JSON content type is refused (CSRF)" test "$CODE" = 415
refute "nothing was created by the refused requests" test -e $ADIR/media.conf

req POST $U/arrays '{"name":"media"}';            expect "an array is created" 201
check "the answer describes it" test "$(echo "$BODY" | jq -r '.name + " " + (.default | tostring) + " " + (.configured | tostring)')" = "media false false"
check "its SnapRAID configuration goes next to the others" test "$(echo "$BODY" | jq -r .engine_conf)" = "$MCONF"
check "it has a configuration file of its own" grep -qx "engine_conf = $MCONF" $ADIR/media.conf
check "that starts with the schedule of the default array" grep -q '^maintenance_schedule = 02:00$' $ADIR/media.conf
refute "and without options of the machine" grep -qE '^(net_|sys_|check_updates|array_parallel)' $ADIR/media.conf
req POST $U/arrays '{"name":"media"}';            expect "the same name twice is refused" 409 "already exists"
req POST $U/arrays "{\"name\":\"other\",\"engine_conf\":\"$MCONF\"}"
expect "two arrays on the same SnapRAID configuration are refused" 409
check "two arrays are listed" test "$(get $U/arrays | jq -r '[.arrays[].name] | join(",")')" = "default,media"
check "the state counts them" test "$(get $U/state | jq -r .arrays_count)" = 2

req GET $U/arrays/nosuch;                         expect "an unknown array is not found" 404
req GET $U/arrays/nosuch/state;                   expect "nor its endpoints" 404
req POST $U/arrays/nosuch/schedule '{"tasks":[{"command":"probe"}]}'; expect "nor its commands" 404
req GET $M/state;                                 expect "the new array has its own state" 200
check "named after it" test "$(echo "$BODY" | jq -r .array)" = media
sleep 3
check "it waits to be configured" test "$(get $M/state | jq -r .health)" = pending
check "and says which file is missing" grep -q "$MCONF" <<< "$(get $M/state | jq -r .health_reason)"
check "the default array did not change" test "$(get $U/state | jq -r .array)" = default
check "the storage inventory of the array points to its file" test "$(get $M/storage | jq -r '.array + " " + .engine_conf.path + " " + (.engine_conf.exists | tostring)')" = "media $MCONF false"

# ---------------------------------------------------------------------------
section "a disk belongs to one array"

for d in d3 d4; do disk $d data; done
disk p2 parity
N="# media array\nparity $T/p2/snapraid.parity\ncontent $LAB/etc/media.content\ncontent $T/d3/snapraid.content\ndata m1 $T/d3\ndata m2 $T/d4\nexclude /lost+found/\n"
conf $M "${N/data m2 $T\/d4/data m2 $T\/d1}";          expect "a data disk of another array is refused" 409 "one array only"
conf $M "${N/data m2 $T\/d4/data m2 $T\/d1\/sub}";     expect "also a folder inside it" 409 "one array only"
conf $M "${N/parity $T\/p2/parity $T\/p1}";            expect "the parity file of another array is refused" 409 "own parity"
conf $M "${N/parity $T\/p2\/snapraid.parity/parity $T\/p1\/other.parity}"
expect "another parity file on the same parity disk is refused" 409 "one array only"
conf $M "${N/parity $T\/p2\/snapraid.parity/parity $T\/d2\/snapraid.parity}"
expect "a parity on a data disk of another array is refused" 409 "either data or parity"
conf $M "${N/data m2 $T\/d4/data m2 $T\/p1}";          expect "a data disk on the parity disk of another array is refused" 409 "either data or parity"
conf $M "${N/content $LAB\/etc\/media.content/content $LAB\/etc\/snapraid.content}"
expect "the content file of another array is refused" 409 "own content"
refute "nothing was written by the refused requests" test -e $MCONF

conf $M "$N";                                     expect "the array is configured with its own disks" 200
check "in its own file" grep -qx "data m2 $T/d4" $MCONF
check "the file of the default array is untouched" test "$(grep -c '^data ' $LAB/etc/snapraid.conf)" = 2
conf $M "${N}content $T/d1/media.content\n";      expect "a content file on a disk of another array is allowed" 200
conf $M "$N"
conf $U "${D}data d3 $T/d3\n";                    expect "the default array cannot take a disk of the new one" 409 "one array only"
check "and its file is still the same" test "$(grep -c '^data ' $LAB/etc/snapraid.conf)" = 2

# ---------------------------------------------------------------------------
section "the arrays work on their own"

fill $T/d3/Series 8 2500; fill $T/d4/Music 25 200
HIST=$(count_task $U sync)
schedule $M '{"command":"probe"},{"command":"sync"}'; expect "probe and sync are scheduled on the new array" 202
tasks_wait $M
check "its first sync succeeds" test "$(last_task sync)" = "terminated 0"
check "its parity is on its own disk" test -s $T/p2/snapraid.parity
check "and its content where it was told" test -s $LAB/etc/media.content
check "the default array ran nothing" test "$(count_task $U sync)" = "$HIST"
check "it is configured now" test "$(get $U/arrays/media | jq -r '(.configured | tostring) + " " + (.data_disks_count | tostring) + " " + (.parity_disks_count | tostring)')" = "true 2 1"
check "and healthy" test "$(health $M)" = passed
check "it knows its disks, not the ones of the default array" test "$(get $M/disks | jq -r '[.data_disks[].name] | sort | join(",")')" = "m1,m2"
check "the default array still has its own" test "$(get $V2/disks | jq -r '[.data_disks[].name] | sort | join(",")')" = "d1,d2"
check "it logs in its own directory" test -n "$(ls $LAB/log/media 2>/dev/null)"
check "the array endpoint tells its configuration" test "$(get $M/array | jq -r .engine_conf)" = "$MCONF"

echo more > $T/d1/Movies/new.bin
schedule $U '{"command":"diff"}'; tasks_wait $U
schedule $M '{"command":"diff"}'; tasks_wait $M
check "a change in the default array is seen there" test "$(get $U/array | jq -r .diff_added)" = 1
check "and not in the other array" test "$(get $M/array | jq -r .diff_added)" = 0
check "the summary of the arrays tells them apart" test "$(get $U/arrays | jq -c '[.arrays[] | .diff_pending]')" = "[1,0]"
schedule $U '{"command":"sync"}'; tasks_wait $U

req PATCH $M/config '{"scrub_percentage":3,"sync_threshold_deletes":7}'; expect "the options of an array are changed" 200
check "in its own file" grep -qx 'scrub_percentage = 3' $ADIR/media.conf
check "and not in the main one" grep -qx 'scrub_percentage = 8' $DCONF
check "the array reports them" test "$(get $M/config | jq -r '.array + " " + (.scrub_percentage | tostring) + " " + (.sync_threshold_deletes | tostring)')" = "media 3 7"
check "the default array keeps its own" test "$(get $V2/config | jq -r '.array + " " + (.scrub_percentage | tostring)')" = "default 8"
req PATCH $M/config '{"array_parallel":true}';    expect "an option of the machine is refused on an array" 400 "machine"
req PATCH $M/config '{"notify_syslog_enabled":true}'; expect "also the syslog ones" 400 "machine"
req POST $M/maintenance '{}';                 expect "a maintenance of the array is accepted" 202
tasks_wait $M
check "a maintenance of the array runs" test "$(echo "$TASKS" | jq -r '[.history[] | select(.command == "scrub")][0].status')" = terminated

# ---------------------------------------------------------------------------
section "recovery of one array"

WANT=$(sums $T/d4); KEEP=$(sums $T/d1; sums $T/d2)
umount $T/d4; mkfs.ext4 -q -F -m 0 -L d4 "$P_d4"
NEWU=$(blkid -p -o value -s UUID "$P_d4")
find /dev/disk/by-uuid -type l -lname "$P_d4" -delete; ln -sf "$P_d4" /dev/disk/by-uuid/$NEWU
sed -i --follow-symlinks "s|^UUID=$U_d4 |UUID=$NEWU |" /etc/fstab
mount $T/d4
schedule $M '{"command":"probe"}'; tasks_wait $M
schedule $U '{"command":"probe"}'; tasks_wait $U
check "the array that lost a disk is degraded" test "$(health $M)" = degraded
check "the other array is not" test "$(health $U)" != degraded
check "the summary shows both" test "$(get $U/arrays | jq -r '[.arrays[] | .health] | join(",")' | sed 's/passed/ok/')" = "ok,degraded"
req POST $U/storage/recover '{"disks":"m2","check":true}'; tasks_wait $U
refute "a recovery sent to the wrong array rebuilds nothing" test -n "$(find $T/d4 -type f ! -name 'snapraid.*')"
req POST $M/storage/recover '{"disks":"m2","check":true}'; expect "the recovery is scheduled on the right array" 200
tasks_wait $M
check "fix succeeded"   test "$(last_task fix)"   = "terminated 0"
check "sync succeeded"  test "$(last_task sync)"  = "terminated 0"
check "every file is back with the same content" test "$(sums $T/d4)" = "$WANT"
check "the array is no more degraded" test "$(health $M)" != degraded
check "the disks of the other array were not touched" test "$(sums $T/d1; sums $T/d2)" = "$KEEP"

# ---------------------------------------------------------------------------
section "one array at a time"

# a hook that takes its time makes the sync of the default array long enough to look at
cat > $LAB/etc/slow-hook.sh <<'HOOK'
#!/bin/sh
echo "$SNAPRAID_ARRAY $1" >> ${LAB_DIR:-/lab}/etc/hook.log
[ "$1" = task-begin ] && sleep 6
exit 0
HOOK
chmod 755 $LAB/etc/slow-hook.sh
req PATCH $V2/config "{\"hook_script\":\"$LAB/etc/slow-hook.sh\"}"; expect "a slow hook is set on the default array" 200
refute "the hook of the default array is not the one of the other" grep -q slow-hook $ADIR/media.conf
echo a > $T/d1/Movies/a.bin; echo b > $T/d3/Series/b.bin
schedule $U '{"command":"sync"}'; sleep 1
schedule $M '{"command":"probe"},{"command":"sync"}'
sleep 3
ST=$(get $M/state)
check "the sync of the second array waits for the first" test "$(echo "$ST" | jq -r .waiting_for)" = default
check "the summary says it too" test "$(get $U/arrays | jq -r '.arrays[1].waiting_for')" = default
check "its probe was not delayed" test "$(get $M/tasks | jq -r '[.history[] | select(.command == "probe")][0].status')" = terminated
check "the default array is not waiting for anybody" test "$(get $U/state | jq -r '.waiting_for // "nobody"')" = nobody
tasks_wait $U; DEND=$(epoch "$(end_of sync)"); check "the first sync succeeds" test "$(last_task sync)" = "terminated 0"
check "the hook is told which array it runs for" grep -qx "default task-begin" $LAB/etc/hook.log
tasks_wait $M; MSTART=$(epoch "$(start_of sync)"); check "then the second one" test "$(last_task sync)" = "terminated 0"
check "started after the first ended" test "$MSTART" -ge "$DEND" -a "$DEND" -gt 0

req PATCH $V2/config '{"array_parallel":true}'; expect "arrays are allowed to run together" 200
check "it is saved in the main configuration" grep -qx 'array_parallel = 1' $DCONF
check "and reported" test "$(get $U/arrays | jq -r .array_parallel)" = true
echo c > $T/d1/Movies/c.bin; echo d > $T/d3/Series/d.bin
schedule $U '{"command":"sync"}'; sleep 1
schedule $M '{"command":"sync"}'
sleep 3
check "with different disks the second array does not wait" test "$(get $M/state | jq -r '.waiting_for // "nobody"')" = nobody
tasks_wait $M; MEND=$(epoch "$(end_of sync)"); check "its sync succeeds" test "$(last_task sync)" = "terminated 0"
tasks_wait $U; DEND=$(epoch "$(end_of sync)"); check "and the one of the default array" test "$(last_task sync)" = "terminated 0"
check "the second ended while the first was still running" test "$MEND" -le "$DEND" -a "$MEND" -gt 0
req PATCH $V2/config '{"array_parallel":false}'; expect "back to one at a time" 200

# ---------------------------------------------------------------------------
section "pools, mounts and what protects them"

pool $T/pool-a "$T/d1:$T/d2";                     expect "a pool on the default array" 200
pool $T/pool-m "$T/d3:$T/d4";                     expect "a second pool on the other array" 200
disk s1 data
pool $T/pool-s "$T/s1";                           expect "a third pool on a disk of no array" 200
INV=$(get $S)
check "three pools are reported" test "$(echo "$INV" | jq '.pools | length')" = 3
bra() { echo "$INV" | jq -c --arg p "$1" '[.pools[] | select(.mountpoint == $p) | .branches[] | [.array // "-", .disk // "-", .protected]]'; }
check "the first is protected by the default array" test "$(bra $T/pool-a)" = '[["default","d1",true],["default","d2",true]]'
check "the second by the other array" test "$(bra $T/pool-m)" = '[["media","m1",true],["media","m2",true]]'
check "the third by nobody" test "$(bra $T/pool-s)" = '[["-","-",false]]'
mnt() { echo "$INV" | jq -r --arg t "$1" '.mounts[] | select(.target == $t) | (.array // "-") + " " + (.role // "-") + " " + (.disk // "-")'; }
check "a data disk tells its array" test "$(mnt $T/d3)" = "media data m1"
check "a parity disk too" test "$(mnt $T/p1)" = "default parity parity"
check "a separate mount is of no array" test "$(mnt $T/s1)" = "- - -"
check "the inventory lists what every array uses" test "$(echo "$INV" | jq -c '[.arrays[] | [.name, (.uses | length)]]')" = '[["default",5],["media",5]]'
check "with the filesystem of every entry" test "$(echo "$INV" | jq -r '.arrays[1].uses[] | select(.name == "m2") | .mount')" = "$T/d4"

pool $T/pool-x "$T/d2:$T/d3:$T/s1";               expect "a pool over two arrays and a loose disk is allowed" 200
INV=$(get $S)
check "and every branch tells who protects it" test "$(bra $T/pool-x)" = '[["default","d2",true],["media","m1",true],["-","-",false]]'
pool $T/pool-y "$T/d1:$T/p2";                     expect "the parity disk of any array is refused in a pool" 400 "parity"
mkdir -p $T/d1/inner
pool $T/pool-z "$T/d1/inner";                     expect "a folder of a data disk can be a branch" 200
INV=$(get $S)
check "and is protected like the disk" test "$(bra $T/pool-z)" = '[["default","d1",true]]'

check "the pools are saved so that they never stop the boot" test "$(grep -c mergerfs /etc/fstab)" = "$(grep mergerfs /etc/fstab | grep -c nofail)"
umount $T/pool-z; mount $T/pool-z 2>/dev/null
check "and fstab alone brings a pool back" test "$(findmnt -n -o FSTYPE $T/pool-z)" = fuse.mergerfs
req POST $S/unmount "{\"target\":\"$T/pool-s\",\"forget\":true}"
req POST $S/unmount "{\"target\":\"$T/s1\",\"forget\":true}"; expect "the loose disk is unmounted" 200
req POST $S/mount "{\"source\":\"$P_s1\",\"target\":\"$T/s1\",\"fstype\":\"ext4\",\"options\":\"defaults,noatime\",\"persist\":true}"
expect "a disk mounted by device name" 200
check "is saved by UUID, and with nofail" grep -qE "^UUID=$U_s1 $T/s1 ext4 defaults,noatime,nofail 0 2$" /etc/fstab

# a balance and a sync of the same disks keep away from each other
echo e > $T/d1/Movies/e.bin
schedule $U '{"command":"sync"}'; sleep 2
req POST $S/balance "{\"mountpoint\":\"$T/pool-a\",\"max_bytes\":\"900000000\",\"spread\":\"5\"}"
expect "a balance is refused while its array syncs" 409 "running a"
req POST $S/balance "{\"mountpoint\":\"$T/pool-m\",\"max_bytes\":\"900000000\",\"spread\":\"5\"}"
expect "the pool of the other array can be balanced meanwhile" 200
job_wait; tasks_wait $U
fill $T/d1/Bulk 24 3000
req POST $S/balance "{\"mountpoint\":\"$T/pool-a\",\"max_bytes\":\"900000000\",\"spread\":\"5\"}"; expect "the balance starts when the array is idle" 200
schedule $U '{"command":"sync"}'
ST=$(get $U/state)
if [ "$(get $S/job | jq -r .job.running)" = true ]; then
    check "a sync waits for the balance of its disks" test "$(echo "$ST" | jq -r .waiting_for)" = storage
else
    skip "a sync waits for the balance of its disks" "the balance finished too quickly"
fi
job_wait; tasks_wait $U
check "and runs when the balance ends" test "$(last_task sync)" = "terminated 0"

# ---------------------------------------------------------------------------
section "metrics"

MET=$(get http://127.0.0.1:7627/metrics)
check "the health of every array is exported" test "$(echo "$MET" | grep -c '^snapraid_arrays_health{array=')" = 2
check "the metrics are of the default array" grep -q '^snapraid_array_data_disks_count 2$' <<< "$MET"
check "or of the one asked" test "$(get 'http://127.0.0.1:7627/metrics?array=media' | grep -c '^snapraid_array_data_disks_count 2$')" = 1
CODE=$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:7627/metrics?array=nosuch')
check "an unknown array is not found" test "$CODE" = 404

# ---------------------------------------------------------------------------
section "arrays added and removed by hand"

PID=$(pgrep -o -x snapraidd)
printf 'engine_conf = %s/etc/snapraid/extra.conf\nmaintenance_schedule = 04:30\n' "$LAB" > $ADIR/extra.conf
printf 'engine_conf = %s/etc/snapraid/bad.conf\nnet_port = 9999\n' "$LAB" > $ADIR/bad.conf
printf 'maintenance_schedule = 04:30\n' > $ADIR/noconf.conf
printf 'engine_conf = %s\n' "$MCONF" > $ADIR/twin.conf
printf 'engine_conf = /x.conf\n' > "$ADIR/Not Valid.conf"
kill -HUP "$PID"; sleep 4
LIST=$(get $U/arrays | jq -r '[.arrays[].name] | join(",")')
check "a new file in the arrays directory is loaded at reload" test "$LIST" = "default,media,extra"
check "with its options" test "$(get $U/arrays/extra/config | jq -r .maintenance_schedule)" = "04:30"
check "one with options of the machine is refused" grep -vq bad <<< "$LIST"
check "one without engine_conf too" grep -vq noconf <<< "$LIST"
check "and one on the configuration of another array" grep -vq twin <<< "$LIST"
rm -f $ADIR/bad.conf $ADIR/noconf.conf $ADIR/twin.conf "$ADIR/Not Valid.conf" $ADIR/extra.conf
sed -i 's/^scrub_percentage = 3$/scrub_percentage = 4/' $ADIR/media.conf
kill -HUP "$PID"; sleep 4
check "a file that is gone removes its array" test "$(get $U/arrays | jq -r '[.arrays[].name] | join(",")')" = "default,media"
check "a changed file is read again" test "$(get $M/config | jq -r .scrub_percentage)" = 4
echo 'net_enabled = 0' >> $ADIR/media.conf
kill -HUP "$PID"; sleep 4
check "a broken file keeps the previous options" test "$(get $M/config | jq -r .scrub_percentage)" = 4
sed -i '/^net_enabled/d' $ADIR/media.conf

# ---------------------------------------------------------------------------
section "removing an array"

req DELETE $U/arrays/default '{}';                expect "the default array cannot be removed" 409 "cannot be removed"
req DELETE $U/arrays/nosuch '{}';                 expect "an unknown array cannot be removed" 404
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $U/arrays/media)
check "a request without the JSON content type is refused (CSRF)" test "$CODE" = 415
req PATCH $M/config "{\"hook_script\":\"$LAB/etc/slow-hook.sh\"}"
echo f > $T/d3/Series/f.bin
schedule $M '{"command":"sync"}'; sleep 2
req DELETE $U/arrays/media '{}';                  expect "an array that is working cannot be removed" 409 "running or queued"
tasks_wait $M
BEFORE=$(sums $T/d3; sums $T/d4)
req DELETE $U/arrays/media '{}';                  expect "an idle array is removed" 200
check "it is no more listed" test "$(get $U/arrays | jq -r '[.arrays[].name] | join(",")')" = default
req GET $M/state;                                 expect "its endpoints are gone" 404
check "its daemon configuration is kept aside" test -f $ADIR/media.conf.removed -a ! -e $ADIR/media.conf
check "its SnapRAID configuration is untouched" grep -qx "data m2 $T/d4" $MCONF
check "its parity is untouched" test -s $T/p2/snapraid.parity
check "its data is untouched" test "$(sums $T/d3; sums $T/d4)" = "$BEFORE"
check "the default array keeps working" test "$(health $U)" = passed
INV=$(get $S)
check "its disks are now of no array" test "$(mnt $T/d3)" = "- - -"

mv $ADIR/media.conf.removed $ADIR/media.conf; kill -HUP "$PID"; sleep 5
tasks_wait $M
check "putting the file back brings the array back" test "$(get $U/arrays | jq -r '[.arrays[].name] | join(",")')" = "default,media"
check "with its disks and history" test "$(get $U/arrays/media | jq -r '(.data_disks_count | tostring) + " " + .health')" = "2 passed"
check "it remembers its past syncs" test "$(count_task $M sync)" -ge 3

# ---------------------------------------------------------------------------
section "reports and hooks name the array"

check "the hook of the second array was told its name" grep -qx "media task-begin" $LAB/etc/hook.log
req PATCH $M/config "{\"hook_script\":\"\",\"notify_result\":\"tee $LAB/etc/report-media.txt\",\"notify_result_level\":\"info\"}"; expect "a notification is set on the second array" 200
req PATCH $V2/config "{\"hook_script\":\"\",\"notify_result\":\"tee $LAB/etc/report-default.txt\",\"notify_result_level\":\"info\"}"
req POST $M/report '{}'; tasks_wait $M
req POST $U/report '{}'; tasks_wait $U
check "the report of the second array says which array it is about" grep -qx "ARRAY: media" $LAB/etc/report-media.txt
refute "the one of the default array is as it always was" grep -q "^ARRAY:" $LAB/etc/report-default.txt
check "and it was written" test -s $LAB/etc/report-default.txt

# ---------------------------------------------------------------------------
section "moving a disk to another array"

# m2 of media, with its files, becomes d4 of the default array: the same steps of the Arrays page
KEEP4=$(sums $T/d4); KEEPALL=$(sums $T/d1; sums $T/d2; sums $T/d3)
PARK=/mnt/snapraid-removed/media-m2
conf $U "${D}data d4 $T/d4\n";                    expect "the disk cannot be added while its array still has it" 409 "one array only"
req POST $S/mkdir "{\"path\":\"$PARK\"}";         expect "an empty folder stands in for the disk" 200
conf $M "${N/data m2 $T\/d4/data m2 $PARK}";       expect "the first array points the disk to the empty folder" 200
schedule $M '{"command":"probe"},{"command":"sync","args":["-E"]}'; tasks_wait $M
check "its sync forgets the disk" test "$(last_task sync)" = "terminated 0"
check "the files are still on the disk" test "$(sums $T/d4)" = "$KEEP4"
conf $M "${N/data m2 $T\/d4\\n/}";                expect "the disk is dropped from the first array" 200
schedule $M '{"command":"probe"}'; tasks_wait $M
conf $U "${D}data d4 $T/d4\n";                    expect "and added to the second" 200
schedule $U '{"command":"probe"},{"command":"sync"}'; tasks_wait $U
check "the sync of the second array protects it" test "$(last_task sync)" = "terminated 0"
check "the second array has one more data disk" test "$(get $V2/disks | jq -r '[.data_disks[].name] | sort | join(",")')" = "d1,d2,d4"
schedule $M '{"command":"probe"}'; tasks_wait $M
check "the first has one less" test "$(get $M/disks | jq -r '[.data_disks[].name] | sort | join(",")')" = "m1"
check "both are healthy" test "$(get $U/arrays | jq -r '[.arrays[].health] | join(",")')" = "passed,passed"
INV=$(get $S)
check "the disk is now of the second array" test "$(mnt $T/d4)" = "default data d4"
check "no file was moved or changed" test "$(sums $T/d4)" = "$KEEP4"
check "nor on the other disks" test "$(sums $T/d1; sums $T/d2; sums $T/d3)" = "$KEEPALL"
check "in the pool it was in, its branch is now protected by the new array" test "$(bra $T/pool-m)" = '[["media","m1",true],["default","d4",true]]'
# it can be rebuilt by its new array
WANT=$(sums $T/d4)
find $T/d4 -mindepth 1 -maxdepth 1 ! -name lost+found ! -name 'snapraid.*' -exec rm -rf {} +
schedule $U '{"command":"fix","args":["-d","d4"]}'; tasks_wait $U
check "and its new parity can rebuild its files" test "$(sums $T/d4)" = "$WANT"

# ---------------------------------------------------------------------------
section "after a restart of the daemon"

kill "$PID"; for _ in $(seq 1 30); do pgrep -x snapraidd >/dev/null || break; sleep 1; done
snapraidd -f -N -c $DCONF -C $LAB/etc/snapraid.conf -p /run/snapraidd.pid >/dev/null 2>&1 &
NEWPID=$!
for _ in $(seq 1 60); do curl -s -o /dev/null $U/state && break; sleep 1; done
tasks_wait $U; tasks_wait $M
check "both arrays are back" test "$(get $U/arrays | jq -r '[.arrays[].name] | join(",")')" = "default,media"
check "the second one with its disks" test "$(get $M/disks | jq -r '[.data_disks[].name] | sort | join(",")')" = "m1"
check "the default one with the disk moved to it" test "$(get $V2/disks | jq -r '[.data_disks[].name] | sort | join(",")')" = "d1,d2,d4"
check "its options" test "$(get $M/config | jq -r .scrub_percentage)" = 4
check "and its history" test "$(count_task $M sync)" -ge 3
check "both healthy" test "$(get $U/arrays | jq -r '[.arrays[].health] | join(",")')" = "passed,passed"
echo g > $T/d3/Series/g.bin
schedule $M '{"command":"sync"}'; tasks_wait $M
check "and working" test "$(last_task sync)" = "terminated 0"
kill "$NEWPID" 2>/dev/null; wait "$NEWPID" 2>/dev/null

# ---------------------------------------------------------------------------
echo
echo "passed $PASS, failed $FAILS, skipped $SKIP"
exit $FAILS
