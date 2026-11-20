#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Checks the settings of the machine of the daemon (/snapraid/v1/host): schedules, shares and
# their users, backups to a USB disk (also when it's plugged in), copies, file operations, the
# wipe of a disk, SMART self-tests, disk power, the folder cache, open files, diagnostics, and
# the backup and restore of the settings.
#
# It works on the showcase lab of docker-compose.yml as it is after the first start. It erases
# the blank USB disk s2 and writes on u1 and x1, the disks in no array:
#
#     docker compose -f docker-compose.machine.yml up --build --abort-on-container-exit --exit-code-from tests
#
# LAB_TEST_SLOW=0 skips the backup started by plugging the disk in, which waits two minutes.
# Every test prints "ok" or "FAIL" with the reason; the exit code is the number of failures.

U=http://127.0.0.1:7627/snapraid/v1
H=$U/host
S=$U/storage
LAB=${LAB_DIR:-/lab}
D=/mnt/lab
PASS=0; FAILS=0; SKIP=0
CODE=; BODY=

[ "$(cat $LAB/etc/lab-preset 2>/dev/null)" = ready ] || { echo "refusing to run: this lab was not started with LAB_PRESET=ready"; exit 99; }
for d in d1 s2 u1 x1; do grep -qx "$d" $LAB/etc/lab-disks || { echo "refusing to run: the lab has no disk $d"; exit 99; }; done

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
bj() { echo "$BODY" | jq -r "$1" 2>/dev/null; }
expect() { # NAME CODE [REGEX on the message]
    if [ "$CODE" != "$2" ]; then fail "$1" "status $CODE instead of $2: $(msg)"; return 1; fi
    if [ -n "${3:-}" ] && ! msg | grep -qiE "$3"; then fail "$1" "message '$(msg)' does not match '$3'"; return 1; fi
    ok "$1"
}
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "failed: $*"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then fail "$name" "unexpectedly true: $*"; else ok "$name"; fi; }
post() { req POST "$H/$1" "$2"; }
host() { curl -s $H | jq -r "$1"; }
job_wait() {
    for _ in $(seq 1 600); do
        JOB=$(curl -s $S/job | jq -c .job)
        [ "$(echo "$JOB" | jq -r .running)" = false ] && return 0
        sleep 1
    done
    return 1
}
job_ok() { job_wait && [ "$(echo "$JOB" | jq -r .success)" = true ]; }
dev_of() { readlink -f "$(findmnt -no SOURCE "$D/$1")" | sed 's/p[0-9]*$//'; }
disk_dev() { # the whole loop device of a disk of the lab, mounted or not
    local loop
    for f in /run/lab/map/*; do [ "$(cat "$f")" = "$1" ] && loop=$(basename "$f"); done
    echo "/dev/$loop"
}

section "status"
req GET $H
expect "the machine answers" 200
check "power actions are only logged in the lab" test "$(host .dry_run)" = true
CONF=$(host .settings_file)
check "the settings file is next to the main configuration" test "$(dirname "$CONF")" = "$LAB/etc"
check "the tools are reported" test "$(host '.tools.rsync')" = true

section "settings"
post settings '{"idle_action":"reboot"}';                expect "an unknown idle action is refused" 400 "none, suspend or shutdown"
post settings '{"maintenance_stop_at":"Sun 07:00"}';      expect "the window end is only a time" 400 "07:00"
post settings '{"smart_short":"sometimes"}';              expect "a wrong schedule is refused" 400 "schedule"
post settings '{"idle_minutes":"5"}';                     expect "idle minutes below 10 are refused" 400 "10 to 1440"
post settings '{"nonsense":"1"}';                         expect "an unknown setting is refused" 400 "unknown"
post settings '{"share.x":"path=/mnt/x"}';                expect "shares have their own request" 400 "of its own"
post settings '{"doc.bays":"not json"}';                  expect "a document is JSON" 400 "JSON"
post settings '{"maintenance_stop_at":"07:00","smart_short":"Sun 03:30","smart_long":"Sat#1 04:30","dircache":"1","dircache_minutes":"1","idle_action":"suspend","idle_minutes":"30","doc.bays":"{\"rows\":2,\"cols\":4,\"slots\":{}}"}'
expect "valid settings are saved" 202
check "they are read back" test "$(host '.settings.maintenance_stop_at + " " + .smart_tests.long + " " + .idle.action')" = "07:00 Sat#1 04:30 suspend"
check "the document comes back as JSON" test "$(host '.docs.bays.cols')" = 4
check "they are in the settings file" grep -q '^smart_short = Sun 03:30$' "$CONF"
post settings '{"idle_action":"","maintenance_stop_at":""}'
check "an empty value removes a setting" test "$(host '.settings.idle_action // "gone"')" = gone
refute "and it's out of the file" grep -q '^maintenance_stop_at' "$CONF"

section "folder cache"
for _ in $(seq 1 30); do [ "$(host .dircache.last_time)" != 0 ] && break; sleep 1; done
check "the folders of the data disks are read" test "$(host .dircache.entries)" -gt 50
check "the kernel keeps them longer" test "$(cat /proc/sys/vm/vfs_cache_pressure)" = 10
post settings '{"dircache":"0"}'
sleep 20
check "turned off, the kernel is back to its default" test "$(cat /proc/sys/vm/vfs_cache_pressure)" = 100

section "shares"
post share_save '{"name":"Movies","path":"/mnt/storage/NoSuchFolder"}';  expect "a missing folder is refused" 404 "does not exist"
post share_save '{"name":"etc","path":"/etc"}';                         expect "a system folder is refused" 400 "system folder|Invalid|not under"
post share_save '{"name":"bad name","path":"/mnt/storage/Movies"}';     expect "a wrong name is refused" 400 "letters"
post share_save '{"name":"Movies","path":"/mnt/storage/Movies","smb":true,"writable":false,"guest":true,"recycle":true,"recycle_days":"7","comment":"Films at home"}'
if [ -d /etc/samba ]; then
    expect "a share is saved" 202
    check "its section is written" grep -q '^\[Movies\]' /etc/samba/snapraidd-shares.conf
    check "read only for everybody" grep -q 'read only = yes' /etc/samba/snapraidd-shares.conf
    check "with its recycle bin" grep -q 'vfs objects = recycle' /etc/samba/snapraidd-shares.conf
    check "smb.conf includes the shares, last" test "$(grep -v '^\s*$' /etc/samba/smb.conf | tail -1)" = "include = /etc/samba/snapraidd-shares.conf"
    check "a copy of smb.conf is kept" test -f /etc/samba/smb.conf.snapraidd.bak
    if command -v testparm >/dev/null; then
        check "Samba accepts it" sh -c 'testparm -s 2>/dev/null | grep -q "^\[Movies\]"'
    fi
    post share_save '{"name":"Movies","path":"/mnt/storage/Movies","smb":true,"guest":true}'
    check "saving again does not add the include twice" test "$(grep -c 'snapraidd-shares.conf' /etc/samba/smb.conf)" = 1
    check "the share is listed" test "$(host '.shares[] | select(.name=="Movies") | .guest')" = true
    if command -v smbpasswd >/dev/null; then
        post share_user_set '{"user":"anna","password":"12"}';             expect "a short password is refused" 400 "4 to 128"
        post share_user_set '{"user":"1anna","password":"secret12"}';      expect "a name starting with a digit is refused" 400 "letter"
        post share_user_set '{"user":"anna","password":"secret12"}';       expect "a share user is added" 202
        check "it's a system user without login" sh -c 'getent passwd anna | grep -q nologin'
        check "Samba knows it" test "$(curl -s $H/share_users | jq -r '.share_users | index("anna") != null')" = true
        post share_save '{"name":"Photos","path":"/mnt/storage/Photos","smb":true,"users":"anna","writable":true}'
        check "a share only for anna" grep -q 'valid users = anna' /etc/samba/snapraidd-shares.conf
        post share_user_delete '{"user":"anna"}';                          expect "the share user is removed" 202
        post share_delete '{"name":"Photos"}'
    else
        skip "share users" "smbpasswd not installed"
    fi
else
    expect "a share is saved without Samba, with a warning" 202
    skip "Samba configuration" "Samba not installed"
fi
post share_save '{"name":"Music","path":"/mnt/storage/Music","smb":false,"nfs":true,"nfs_hosts":"192.168.1.0/24,10.0.0.5"}'
check "an NFS export is written, quoted, with an fsid for the pool" grep -qE '^"/mnt/storage/Music" 192.168.1.0/24\(rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=[0-9]+,fsid=[0-9]+\) 10.0.0.5' /etc/exports.d/snapraidd.exports
post share_delete '{"name":"Music"}'
refute "a removed share leaves the exports" grep -q Music /etc/exports.d/snapraidd.exports
post share_delete '{"name":"Movies"}'
refute "and Samba" grep -q '^\[Movies\]' /etc/samba/snapraidd-shares.conf

section "permissions"
mkdir -p $D/x1/perm/sub && touch $D/x1/perm/sub/f && chmod 600 $D/x1/perm/sub/f
post permissions '{"path":"/mnt/lab/x1/perm"}'
expect "permissions reset starts" 202
check "it ends" job_ok
check "files belong to the share users" test "$(stat -c %U:%G $D/x1/perm/sub/f)" = nobody:users
check "and they can write them" test "$(stat -c %a $D/x1/perm/sub/f)" = 664
check "folders can be entered" test "$(stat -c %a $D/x1/perm/sub)" = 775
post permissions '{"path":"/etc/ssh"}';  expect "a system folder is refused" 400

section "files"
mkdir -p "$D/x1/My Folder/inner" && echo hi > "$D/x1/My Folder/inner/a b.txt" && mkdir -p $D/x1/other
post file_rename '{"path":"/mnt/lab/x1/My Folder","name":"Renamed Folder"}'; expect "a folder with spaces is renamed" 202
check "it has the new name" test -f "$D/x1/Renamed Folder/inner/a b.txt"
post file_rename '{"path":"/mnt/lab/x1/Renamed Folder","name":"other"}';     expect "renaming over another is refused" 409 "already exists"
post file_rename '{"path":"/mnt/lab/x1/other","name":"../escape"}';         expect "a name with a slash is refused" 400
post file_rename '{"path":"/mnt/lab/x1","name":"x9"}';                       expect "a mount point is not renamed" 400 "mount point"
post file_delete '{"path":"/mnt/lab/x1"}';                                   expect "a mount point is not deleted" 400 "mounted"
post file_delete '{"path":"/mnt/lab/x1/../../../etc"}';                      expect "climbing out is refused" 400
post file_delete '{"path":"/mnt/lab/x1/Renamed Folder"}';                    expect "a folder is deleted" 202
refute "it's gone" test -e "$D/x1/Renamed Folder"
ln -s /etc $D/x1/escape
post file_delete '{"path":"/mnt/lab/x1/escape/hostname"}';                   expect "a link leading out of the disks is not followed" 400 "link"
check "and what it points to is untouched" test -f /etc/hostname
post share_save '{"name":"escape","path":"/mnt/lab/x1/escape"}';            expect "a share through such a link is refused" 400 "links"
post file_delete '{"path":"/mnt/lab/x1/escape"}';                            expect "the link itself is deleted" 202
check "as a link" test -d /etc
rm -rf $D/x1/other $D/x1/perm

section "copy"
post copy '{"source":"/mnt/storage/Music","target":"/mnt/storage/Music/inside"}';  expect "a copy into itself is refused" 400 "inside"
post copy '{"source":"/mnt/storage/Music","target":"/mnt/lab/x1/music"}';          expect "a copy starts" 202
check "it ends" job_ok
check "every file is there" test "$(find /mnt/storage/Music -type f | wc -l)" = "$(find $D/x1/music -type f | wc -l)"
check "the times are kept" test "$(stat -c %Y "$(find /mnt/storage/Music -type f | head -1)")" = "$(stat -c %Y "$D/x1/music/$(cd /mnt/storage/Music && find . -type f | head -1)")"
check "the job counted the bytes" test "$(echo "$JOB" | jq -r .bytes)" -gt 0
rm -rf $D/x1/music

section "backups"
UUID=$(blkid -s UUID -o value "$(findmnt -no SOURCE $D/u1)")
post backup_save '{"name":"photos","source":"/mnt/storage/Photos","dest_dir":"Backups/Photos"}';  expect "a backup needs a destination" 400 "destination"
post backup_save "{\"name\":\"photos\",\"source\":\"/mnt/storage/Photos\",\"dest_uuid\":\"$UUID\",\"dest_dir\":\"Backups/Photos\",\"when\":\"Sun 05:00\",\"plug\":true}"
expect "a backup to the USB disk is saved" 202
echo extra > $D/u1/keep-me.txt
mkdir -p $D/u1/Backups/Photos && echo old > $D/u1/Backups/Photos/only-in-the-copy.txt
post backup_run '{"name":"photos"}';  expect "it runs" 202
check "it ends" job_ok
check "the photos are on the USB disk" test "$(find /mnt/storage/Photos -type f | wc -l)" = "$(find $D/u1/Backups/Photos -type f ! -name only-in-the-copy.txt | wc -l)"
check "without mirror nothing is deleted from the copy" test -f $D/u1/Backups/Photos/only-in-the-copy.txt
check "its result is recorded" test "$(host '.backups[] | select(.name=="photos") | .last_status')" = 0
check "and it says the disk is there" test "$(host '.backups[] | select(.name=="photos") | .plugged')" = true
post backup_save "{\"name\":\"photos\",\"source\":\"/mnt/storage/Photos\",\"dest_uuid\":\"$UUID\",\"dest_dir\":\"Backups/Photos\",\"mirror\":true,\"plug\":true}"
post backup_run '{"name":"photos"}'; job_ok
refute "with mirror the copy follows the deletions" test -f $D/u1/Backups/Photos/only-in-the-copy.txt
check "what is outside the folder of the backup is never touched" test -f $D/u1/keep-me.txt

# a disk plugged in but not mounted: mounted for the run, released after
umount $D/u1
post backup_run '{"name":"photos"}';  expect "a backup of an unmounted disk starts" 202
check "it ends" job_ok
refute "the disk is released after" findmnt /mnt/backup-photos
mount "UUID=$UUID" $D/u1

if [ "${LAB_TEST_SLOW:-1}" = 1 ]; then
    # unplugging and plugging the disk again starts the backup
    before=$(host '.backups[] | select(.name=="photos") | .last_time')
    umount $D/u1
    mv /dev/disk/by-uuid/$UUID /run/lab/unplugged-$UUID
    sleep 70
    check "an unplugged disk is reported" test "$(host '.backups[] | select(.name=="photos") | .plugged')" = false
    mv /run/lab/unplugged-$UUID /dev/disk/by-uuid/$UUID
    for _ in $(seq 1 120); do
        now=$(host '.backups[] | select(.name=="photos") | .last_time')
        [ "$now" != "$before" ] && break
        sleep 1
    done
    check "plugging the disk in runs the backup" test "$now" != "$before"
    check "and it worked" test "$(host '.backups[] | select(.name=="photos") | .last_status')" = 0
    job_wait
    findmnt $D/u1 >/dev/null || mount "UUID=$UUID" $D/u1
else
    skip "backup when the disk is plugged in" "LAB_TEST_SLOW=0"
fi
post backup_delete '{"name":"photos"}';  expect "the backup is deleted" 202
check "with its last result" test "$(grep -c 'photos' "$CONF")" = 0
check "the copies stay" test -d $D/u1/Backups/Photos
rm -rf $D/u1/Backups $D/u1/keep-me.txt

section "wipe"
S2=$(disk_dev s2); D1=$(disk_dev d1); U1=$(disk_dev u1)
post wipe "{\"device\":\"$D1\",\"method\":\"zero\",\"confirm\":\"$D1\"}";  expect "a disk of an array is refused" 409 "array"
post wipe "{\"device\":\"$U1\",\"method\":\"zero\",\"confirm\":\"$U1\"}";  expect "a mounted disk is refused" 409 "mounted"
post wipe "{\"device\":\"${U1}p1\",\"method\":\"zero\",\"confirm\":\"${U1}p1\"}";  expect "a partition is refused" 400 "whole disk"
post wipe "{\"device\":\"$S2\",\"method\":\"zero\",\"confirm\":\"/dev/sdz\"}";  expect "without the right confirmation it's refused" 400 "confirm"
post wipe "{\"device\":\"$S2\",\"method\":\"fast\",\"confirm\":\"$S2\"}";  expect "an unknown method is refused" 400 "zero, random or test"
head -c 1M /dev/urandom | dd of=$S2 bs=1M conv=notrunc status=none
post wipe "{\"device\":\"$S2\",\"method\":\"zero\",\"confirm\":\"$S2\"}";  expect "a blank disk is wiped" 202
check "it ends" job_ok
check "all of it" test "$(echo "$JOB" | jq -r .bytes)" = "$(blockdev --getsize64 $S2)"
check "it's zero" test "$(head -c 1M $S2 | tr -d '\0' | wc -c)" = 0

section "open files"
( cd $D/d1 && sleep 20 ) &
sleep 1
req GET "$H/openfiles?path=$D/d1"
expect "the open files of a disk are listed" 200
check "a program working in it is found" test "$(echo "$BODY" | jq '[.processes[] | select(.name=="sleep" and .cwd)] | length')" -ge 1
req GET "$H/openfiles?path=/mnt/../etc";  expect "a path climbing out is refused" 400
kill %1 2>/dev/null; wait 2>/dev/null

section "SMART self-tests and power"
D1N=$(dev_of d1)
post smart_test "{\"device\":\"$D1N\",\"kind\":\"forever\"}";  expect "an unknown test is refused" 400 "short or long"
post smart_test '{"device":"/dev/../etc/passwd","kind":"short"}';  expect "a device must be a disk" 400
post smart_test "{\"device\":\"$D1N\",\"kind\":\"short\"}";  expect "a short self-test starts" 202
req GET "$H/smart?device=$D1N"
expect "its log is read" 200
check "and it says it's running" test "$(bj .text | grep -c 'in progress')" -ge 1
post power_save "{\"disk\":\"$(curl -s http://127.0.0.1:7627/snapraid/v2/disks | jq -r '[.data_disks[] | select(.name=="d1") | .devices[0].serial][0]')\",\"apm\":\"127\",\"wcache\":true}"
expect "power settings are saved" 202
check "a disk refusing them is told" test "$(echo "$BODY" | jq -r .applied)" = false
check "they are kept for the next start" test "$(host '.power[0].apm')" = 127
post power_save '{"disk":"no-such-disk","apm":"1"}'
check "a disk not in the arrays gets a warning" test "$(bj .warning | grep -c 'not in any array')" = 1

section "network"
req GET $H/network
expect "the network cards are listed" 200
check "with their address" test "$(echo "$BODY" | jq '[.interfaces[] | select(.mac != "")] | length')" -ge 1

section "diagnostics"
req GET $H/diagnostics
expect "diagnostics are made" 200
TXT=$(bj .text)
check "named with the date" test "$(bj .filename | grep -cE '^snapraidd-diagnostics-[0-9]{8}-[0-9]{4}\.txt$')" = 1
check "with the configurations" test "$(echo "$TXT" | grep -c '===== Daemon configuration')" = 1
check "the commands of the notifications are removed" test "$(echo "$TXT" | grep -c 'notify_result = <removed>')" -ge 1
check "no serial number of the disks" test "$(echo "$TXT" | grep -c 'LAB1000D1')" = 0
if [ ${#HOSTNAME} -ge 3 ]; then
    check "no name of the machine" test "$(echo "$TXT" | grep -cw "$HOSTNAME")" = 0
else
    skip "no name of the machine" "the name is too short to be told apart"
fi

section "backup and restore of the settings"
req GET $H/settings_backup
expect "the settings are given" 200
check "with the daemon configuration" test "$(bj '.files[].path' | grep -c "^$LAB/etc/snapraidd.conf$")" = 1
check "and the settings of the machine" test "$(bj '.files[].path' | grep -c snapraidd-host.conf)" = 1
post restore '{"path":"/etc/passwd","text":"x"}';  expect "a file not of the settings is refused" 400 "not one of the settings"
# a SnapRAID configuration goes through the checks of the Configuration page: here a disk of another array
BAD=$(sed "s|^data d4 .*|data d4 $D/m1|" $LAB/etc/snapraid.conf | jq -Rs .)
post restore "{\"path\":\"$LAB/etc/snapraid.conf\",\"text\":$BAD}"
expect "a SnapRAID configuration using a disk of another array is refused" 409
check "and the old one stays" grep -q "^data d4 $D/d4" $LAB/etc/snapraid.conf
NEW=$(printf '# restored\nsmart_short = Mon 01:15\n' | jq -Rs .)
post restore "{\"path\":\"$CONF\",\"text\":$NEW}";  expect "the settings of the machine are restored" 202
check "and applied at once" test "$(host .smart_tests.short)" = "Mon 01:15"
check "the old file is kept" test -f "$CONF.before-restore"
post settings '{"smart_short":"","smart_long":""}'

section "the lab as it was"
# u1 is an 'extra' disk of the default array, unmounted and mounted again by the backups:
# the array reads its state again
req POST $U/refresh '{}'
for _ in $(seq 1 90); do
    [ "$(curl -s $U/arrays | jq -r '[.arrays[] | select(.health != "passed")] | length')" = 0 ] && break
    sleep 1
done
check "every array is healthy after the tests" test "$(curl -s $U/arrays | jq -r '[.arrays[] | select(.health != "passed")] | length')" = 0

echo
echo "machine tests: $PASS ok, $FAILS failed, $SKIP skipped"
exit $FAILS
