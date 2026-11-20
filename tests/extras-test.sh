#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Checks the write test of a new disk, the record of the runs with the errors found and fixed,
# the update of the protection when enough files changed, the battery backup (UPS), the disks
# mounted for a while and ejected, the folders of other computers as sources of a backup, and
# the alerts sent to more channels at once.
#
# It works on the showcase lab of docker-compose.yml as it is after the first start. It
# overwrites the blank disk s2 and writes on x1 and u1:
#
#     docker compose -f docker-compose.extras.yml up --build --abort-on-container-exit --exit-code-from tests
#
# The lab has no UPS, no other computer and no mail: small stand-ins of upsc, mount.cifs and
# mail are written for the time of the tests, and removed at the end.
# LAB_TEST_SLOW=0 skips the update started by the changes, which waits some minutes.
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
for d in d1 d2 p1 s2 x1 u1; do grep -qx "$d" $LAB/etc/lab-disks || { echo "refusing to run: the lab has no disk $d"; exit 99; }; done

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
host() { curl -s $H | jq -r "$1"; }
runs() { curl -s "$H/runs?array=default&limit=${2:-50}" | jq -r "$1"; } # the other arrays of the lab run too
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
last_task() { curl -s "$U/tasks?limit_history=12&limit_messages=20" | jq -r "[.history[] | select(.command == \"$1\")][0] | $2"; }
schedule() { req POST $U/schedule "{\"tasks\":[$1]}"; }
disk_dev() { # the whole loop device of a disk of the lab, mounted or not
    local loop
    for f in /run/lab/map/*; do [ "$(cat "$f")" = "$1" ] && loop=$(basename "$f"); done
    echo "/dev/$loop"
}
wait_for() { # SECONDS COMMAND...: until the command is true
    local n=$1; shift
    for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
    return 1
}

# stand-ins of the tools the lab has not
STAND=/run/lab/standins
mkdir -p $STAND/ups $STAND/smb/photos/2024 $STAND/smb/photos/2025 $STAND/mail
echo "a picture" > $STAND/smb/photos/2024/one.jpg
echo "another picture" > $STAND/smb/photos/2025/two.jpg
echo "a note" > $STAND/smb/photos/readme.txt
cat > /usr/local/bin/upsc <<EOF
#!/bin/sh
# Stand-in of upsc (NUT) for the lab: the state of the UPS "labups" is the file $STAND/ups/state
[ "\$1" = "-l" ] && { echo labups; exit 0; }
[ "\$1" = "labups" ] || { echo "Error: Unknown UPS" >&2; exit 1; }
cat $STAND/ups/state 2>/dev/null || { echo "Error: Data stale" >&2; exit 1; }
EOF
cat > /sbin/mount.cifs <<EOF
#!/bin/sh
# Stand-in of mount.cifs for the lab: the shared folder //lab/NAME is the folder $STAND/smb/NAME,
# and the only password accepted is "secret".
src=\$1; dst=\$2; shift 2
opts=
while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && { opts=\$2; shift; }; shift; done
echo "\$src \$dst \$opts" >> $STAND/smb/calls.log
case "\$src" in //lab/*) ;; *) echo "mount error(113): could not connect to \$src" >&2; exit 32 ;; esac
dir=$STAND/smb/\${src#//lab/}
[ -d "\$dir" ] || { echo "mount error(2): No such file or directory" >&2; exit 32; }
cred=\$(echo "\$opts" | tr ',' '\n' | sed -n 's/^credentials=//p')
if [ -n "\$cred" ]; then grep -qx 'password=secret' "\$cred" || { echo "mount error(13): Permission denied" >&2; exit 32; }; fi
mount --bind "\$dir" "\$dst" && mount -o remount,bind,ro "\$dst"
EOF
cat > /usr/local/bin/mail <<EOF
#!/bin/sh
# Stand-in of mail for the lab: a message for X is added to the file $STAND/mail/X
[ "\$1" = "-s" ] || exit 2
{ echo "Subject: \$2"; cat; echo "--"; } >> "$STAND/mail/\$3"
EOF
chmod 755 /usr/local/bin/upsc /sbin/mount.cifs /usr/local/bin/mail
cleanup() { rm -f /usr/local/bin/upsc /sbin/mount.cifs /usr/local/bin/mail; }
trap cleanup EXIT

tasks_wait
CONFDIR=$(dirname "$(host .settings_file)")

section "write test of a new disk"
S2=$(disk_dev s2)
post wipe "{\"device\":\"$(disk_dev d1)\",\"confirm\":\"$(disk_dev d1)\",\"method\":\"test\"}"; expect "a disk of an array is never tested by writing" 409 "disk d1 of the array"
post wipe "{\"device\":\"$S2\",\"confirm\":\"yes\",\"method\":\"test\"}";                        expect "the test asks for the name of the disk" 400 "confirm"
post wipe "{\"device\":\"$S2\",\"confirm\":\"$S2\",\"method\":\"shake\"}";                       expect "an unknown method is refused" 400 "zero, random or test"
post wipe "{\"device\":\"$S2\",\"confirm\":\"$S2\",\"method\":\"test\"}";                        expect "the write test starts" 202
check "it ends well" job_ok
check "it is a job of its own kind" test "$(jobf .kind)" = burnin
check "it says every block was written and read back" grep -q "written and read back without a single error" <<< "$(jobf .message)"
SIZE=$(blockdev --getsize64 "$S2")
check "it went twice over the disk" test "$(jobf .bytes)" = $((SIZE * 2))
refute "the disk is blank after it" blkid "$S2"
check "the start of the disk is zero" test "$(head -c 1048576 "$S2" | tr -d '\0' | wc -c)" = 0

section "record of the runs"
BEFORE=$(runs .total 1)
req POST $U/maintenance '{}'; tasks_wait
check "a sync and a scrub are recorded" test "$(runs .total 1)" -ge $((BEFORE + 2))
check "the newest is first" test "$(runs '.runs[0].command + " " + .runs[0].result + " " + .runs[1].command')" = "scrub ok sync"
check "the record is a file next to the settings" grep -qP "\tdefault\tscrub\tok\t0\t" "$CONFDIR/snapraidd-runs.log"
check "the runs of another array are apart" test "$(curl -s "$H/runs?array=flash" | jq -r '[.runs[] | select(.array != "flash")] | length')" = 0
check "an array without runs has none" test "$(curl -s "$H/runs?array=nosucharray" | jq -r .total)" = 0
# silent damage: some bytes of a protected file change, its size and time stay
VICTIM=$(find $D/d1 -type f -size +64k ! -name 'snapraid.content*' | sort | head -1)
STAMP=$(stat -c %y "$VICTIM")
head -c 4096 /dev/urandom | dd of="$VICTIM" bs=4096 seek=4 conv=notrunc status=none
touch -d "$STAMP" "$VICTIM"
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
schedule '{"command":"scrub","args":["-p","100","-o","0"]}'; tasks_wait
check "a scrub that finds damage is recorded with the errors" test "$(runs '.runs[0].command + " " + .runs[0].result + " " + (.runs[0].errors_data > 0 | tostring)')" = "scrub error true"
check "the errors are summed up" test "$(runs .errors_found 1)" -ge 1
schedule '{"command":"fix","args":["-e"]}'; tasks_wait
check "the fix is recorded with what it recovered" test "$(runs '.runs[0].command + " " + (.runs[0].recovered > 0 | tostring) + " " + (.runs[0].unrecoverable | tostring)')" = "fix true 0"
check "the fixed errors are summed up" test "$(runs .errors_fixed 1)" -ge 1
schedule '{"command":"scrub","args":["-p","bad"]}'; tasks_wait
check "the scrub of what was damaged is clean" test "$(runs '.runs[0].command + " " + .runs[0].result')" = "scrub ok"
LINES=$(grep -vc '^#' "$CONFDIR/snapraidd-runs.log")
sleep 62
check "a run is recorded once" test "$(grep -vc '^#' "$CONFDIR/snapraidd-runs.log")" = "$LINES"

section "battery backup"
online() { printf 'battery.charge: %s\nbattery.runtime: %s\nups.status: OL CHRG\n' "${1:-100}" "${2:-2400}" > $STAND/ups/state; }
battery() { printf 'battery.charge: %s\nbattery.runtime: %s\nups.status: OB DISCHRG%s\n' "$1" "$2" "${3:-}" > $STAND/ups/state; }
look() { post settings '{"ups_minutes":"5"}'; sleep 2; } # a saved setting makes the daemon look at once
online
post settings '{"ups":"usb"}';                 expect "an unknown kind of UPS is refused" 400 "apc, or nut:"
post settings '{"ups":"nut:-l"}';              expect "a name that is an option is refused" 400 "apc, or nut:"
post settings '{"ups_percent":"99"}';          expect "the charge to shut down at has limits" 400 "5 to 95"
check "the units of the machine are found" test "$(curl -s $H/ups_detect | jq -r '.found | join(",")')" = "nut:labups"
check "without a UPS chosen nothing is watched" test "$(host .ups.state)" = off
post settings '{"ups":"nut:labups","ups_shutdown":"1","ups_percent":"20","ups_minutes":"5"}'; expect "the UPS is chosen" 202
sleep 2
check "on the mains it says so, with the charge" test "$(host '.ups.state + " " + (.ups.charge | tostring) + " " + (.ups.runtime_seconds | tostring)')" = "online 100 2400"
# a scrub is held still, so the look of the daemon finds it running
schedule '{"command":"scrub","args":["-p","100","-o","0"]}'
wait_for 20 pgrep -x snapraid; pkill -STOP -x snapraid
battery 80 1500; look
check "a power cut is seen" test "$(host .ups.state)" = battery
pkill -CONT -x snapraid; tasks_wait
check "the scrub was stopped" grep -qE "signaled|Stop requested" <<< "$(last_task scrub '.status + " " + ([.messages[].text] | join(" "))')"
check "the stop is counted" test "$(host .ups.stopped)" -ge 1
wait_for 70 test "$(runs '.runs[0].result')" = stopped
check "and recorded as stopped, not as an error" test "$(runs '.runs[0].command + " " + .runs[0].result')" = "scrub stopped"
refute "with charge left the machine stays on" test "$(host .ups.shutdown)" = true
battery 15 900; look; look
check "below the chosen charge it shuts down (dry run)" test "$(host .ups.shutdown)" = true
online 16 300; look
check "the power back is seen" test "$(host .ups.state)" = online
battery 90 200; look
refute "one read asking for the shutdown is not enough" test "$(host .ups.shutdown)" = true
look
check "the minutes left count too" test "$(host .ups.shutdown)" = true
online; look
battery 50 2000 " LB"; look; look
check "the UPS saying low battery counts too" test "$(host '.ups.state + " " + (.ups.shutdown | tostring)')" = "low true"
online; look
post settings '{"ups_shutdown":"0"}'
battery 5 30; look; look
refute "with the shutdown turned off it only pauses" test "$(host .ups.shutdown)" = true
rm $STAND/ups/state; look
check "a UPS that stops answering is not a power cut" test "$(host '.ups.state + " " + .ups.error')" = "unknown The UPS does not answer"
online; look
post settings '{"ups":"","ups_shutdown":"","ups_percent":"","ups_minutes":""}'; sleep 2
check "turned off, nothing is watched" test "$(host .ups.state)" = off

section "disks mounted for a while and ejected"
X1=$(disk_dev x1); U1=$(disk_dev u1); UPART=${U1}p1
post usb_eject "{\"device\":\"$(disk_dev d1)\"}";    expect "a disk of an array is never ejected" 409 "disk d1 of the array"
post usb_eject "{\"device\":\"$X1\"}";               expect "a disk of a pool is not ejected" 409 "part of the pool /mnt/scratch"
check "it stays mounted" mountpoint -q $D/x1
post usb_eject '{"device":"/dev/nosuchdisk"}';       expect "a device that is not there is refused" 400 "not a disk"
echo "kept" > $D/u1/lab-extras.txt
exec 9< $D/u1/lab-extras.txt
post usb_eject "{\"device\":\"$U1\"}";               expect "a disk with an open file is not ejected" 409 "in use"
exec 9<&-
check "and stays mounted" mountpoint -q $D/u1
post usb_eject "{\"device\":\"$U1\"}";               expect "the disk is ejected" 202
check "the answer says it can be unplugged" grep -q unplugged <<< "$(echo "$BODY" | jq -r .note)"
refute "nothing of it is mounted" grep -q "^$UPART " /proc/self/mounts
post usb_mount '{"device":"/dev/nosuchdisk"}';       expect "to mount, a device that is not there is refused" 400 "not a disk"
post usb_mount '{"device":"/etc/passwd"}';           expect "a file is not a disk" 400 "not a disk"
post usb_mount "{\"device\":\"$(disk_dev d1)p1\"}";  expect "a disk of an array is never opened apart" 409 "disk d1 of the array"
post usb_mount "{\"device\":\"$UPART\"}";            expect "a filesystem is mounted with one request" 202
UM=$(echo "$BODY" | jq -r .target)
check "under /media" grep -q '^/media/' <<< "$UM"
check "it is there" mountpoint -q "$UM"
refute "nothing new is written in fstab" grep -q "$UM" /etc/fstab
check "what was written before is on the disk" grep -qx kept "$UM/lab-extras.txt"
post usb_mount "{\"device\":\"$UPART\"}"
check "asked twice it stays where it is" test "$(echo "$BODY" | jq -r .target)" = "$UM"
rm -f "$UM/lab-extras.txt"
post usb_eject "{\"device\":\"$UPART\"}";            expect "a part of the disk ejects the whole disk" 202
refute "its folder under /media is gone" test -e "$UM"
mount $D/u1
check "the disk of the lab is back in its place" mountpoint -q $D/u1

section "folders of other computers"
post remote_save '{"name":"bad name","kind":"smb","host":"lab","share":"photos"}';             expect "a wrong name is refused" 400 "letters"
post remote_save '{"name":"nas","kind":"ftp","host":"lab","share":"photos"}';                  expect "an unknown kind is refused" 400 "smb .*or nfs"
post remote_save '{"name":"nas","kind":"smb","host":"lab;reboot","share":"photos"}';           expect "a host with odd characters is refused" 400 "host"
post remote_save '{"name":"nas","kind":"smb","host":"-oexec","share":"photos"}';               expect "a host that is an option is refused" 400 "host"
post remote_save '{"name":"nas","kind":"smb","host":"lab","share":"photos,exec"}';             expect "a share with a comma is refused" 400 "shared folder"
post remote_save '{"name":"nas","kind":"smb","host":"lab","share":"photos","user":"anna"}';    expect "a user needs a password" 400 "password"
post settings '{"remote.nas":"kind=smb\thost=lab\tshare=photos"}';                             expect "they have their own request" 400 "of its own"
post remote_save '{"name":"nas","kind":"smb","host":"lab","share":"photos","user":"anna","password":"wrong"}'; expect "a folder is saved" 202
check "it is listed without the password" test "$(host '.remotes[0] | .name + " " + .kind + " " + .host + " " + .share + " " + .user + " " + (.password | tostring) + " " + (.mounted | tostring)')" = "nas smb lab photos anna true false"
refute "the password is not in the settings" grep -q wrong "$CONFDIR/snapraidd-host.conf"
check "it is in a file only root reads" test "$(stat -c %a "$CONFDIR/snapraidd-remote-nas.cred")" = 600
post remote_test '{"name":"nas"}';                   expect "a wrong password is told in plain words" 502 "refused the name or the password"
post remote_save '{"name":"nas","kind":"smb","host":"lab","share":"photos","user":"anna","password":"secret"}'
post remote_test '{"name":"nas"}';                   expect "with the right one it is read" 202
check "its folders are listed" test "$(echo "$BODY" | jq -r '.folders | sort | join(",")')" = "2024,2025"
check "with the count of what is inside" test "$(echo "$BODY" | jq -r .entries)" = 3
refute "after the look it is not left mounted" mountpoint -q /mnt/remote/nas
check "it was asked read-only and without programs" grep -q "^//lab/photos /mnt/remote/nas ro,nosuid,nodev,noexec,.*credentials=$CONFDIR/snapraidd-remote-nas.cred" $STAND/smb/calls.log
post remote_save '{"name":"nas","kind":"smb","host":"lab","share":"photos","user":"anna"}';    expect "saved again without a password it keeps the one it has" 202
post remote_test '{"name":"nas"}';                   expect "and still reads" 202
post remote_save '{"name":"gone","kind":"smb","host":"lab","share":"nosuchshare"}'
post remote_test '{"name":"gone"}';                  expect "a share that is not there is told" 502 "no shared folder with this name"
post remote_save '{"name":"far","kind":"smb","host":"elsewhere","share":"photos"}'
post remote_test '{"name":"far"}';                   expect "a computer that does not answer is told" 502 "does not answer"
check "a folder without a user is asked as a guest" grep -q "^//elsewhere/photos .*,guest" $STAND/smb/calls.log
post remote_delete '{"name":"gone"}'; post remote_delete '{"name":"far"}'
post remote_test '{"name":"gone"}';                  expect "a deleted folder is not known" 404
# a backup that copies from the other computer
mkdir -p $POOL/FromNas
post backup_save "{\"name\":\"nas-photos\",\"source\":\"/mnt/remote/nas\",\"dest_path\":\"$POOL/FromNas\",\"mirror\":true}"; expect "a backup from the folder is saved" 202
post backup_run '{"name":"nas-photos"}';             expect "it starts" 202
check "it ends well" job_ok
check "the files of the other computer are here" test "$(cat $POOL/FromNas/2024/one.jpg 2>/dev/null)" = "a picture"
check "all of them" test "$(find $POOL/FromNas -type f | wc -l)" = 3
refute "the folder is released after the run" mountpoint -q /mnt/remote/nas
check "the run is recorded" test "$(host '.backups[] | select(.name == "nas-photos") | .last_status')" = 0
post backup_save "{\"name\":\"nas-sub\",\"source\":\"/mnt/remote/nas/2025\",\"dest_path\":\"$POOL/FromNas2025\"}"
mkdir -p $POOL/FromNas2025
post backup_run '{"name":"nas-sub"}'; job_wait
check "a folder inside it can be the source" test "$(cat $POOL/FromNas2025/two.jpg 2>/dev/null)" = "another picture"
post remote_delete '{"name":"nas"}';                 expect "a folder used by a backup is not deleted" 409 "backup nas-"
mv $STAND/smb/photos $STAND/smb/photos.off
post backup_run '{"name":"nas-photos"}';             expect "a run that cannot reach the other computer fails" 502
check "and the failure is recorded for the Backups page" test "$(host '.backups[] | select(.name == "nas-photos") | .last_status')" = 502
check "the files copied before are kept" test "$(find $POOL/FromNas -type f | wc -l)" = 3
mv $STAND/smb/photos.off $STAND/smb/photos
post backup_delete '{"name":"nas-photos"}'; post backup_delete '{"name":"nas-sub"}'
post remote_delete '{"name":"nas"}';                 expect "without backups it is deleted" 202
refute "its password too" test -e "$CONFDIR/snapraidd-remote-nas.cred"
check "none is left" test "$(host '.remotes | length')" = 0
post remote_save '{"name":"box","kind":"nfs","host":"lab","share":"/export/data"}';            expect "an NFS folder is saved" 202
refute "it has no password file" test -e "$CONFDIR/snapraidd-remote-box.cred"
post remote_delete '{"name":"box"}'
rm -rf $POOL/FromNas $POOL/FromNas2025

section "alerts on more channels"
post alerts_save '{"channels":"kind=email\tto=anna@lab; reboot"}';                       expect "an address with odd characters is refused" 400 "to"
post alerts_save '{"channels":"kind=ntfy\turl=ftp://x.example/t"}';                       expect "only web addresses are taken" 400 "url"
post alerts_save "{\"channels\":\"kind=webhook\\turl=https://x.example/a'b\"}";           expect "a quote in an address is refused" 400 "url"
post alerts_save '{"channels":"kind=telegram\ttoken=123:abc"}';                           expect "a channel with a missing field is refused" 400 "not complete"
post alerts_save '{"channels":"kind=pigeon\turl=https://x.example/a"}';                   expect "an unknown channel is refused" 400 "not complete"
post alerts_save '{"channels":"kind=email\tto=anna@lab\nkind=email\tto=bob@lab\nkind=ntfy\turl=https://ntfy.lab/topic-1\nkind=discord\turl=https://discord.lab/api/webhooks/1/abc\nkind=telegram\ttoken=123:abc_DEF\tchat=-100200"}'
expect "five channels are saved" 202
CMD=$(echo "$BODY" | jq -r .command)
SCRIPT=$CONFDIR/snapraidd-alerts.sh
check "the answer is the command for the reports" test "$CMD" = "$SCRIPT \"%s\" \"%n\" \"%t\""
check "the script is for root only" test "$(stat -c %a "$SCRIPT")" = 700
check "it is a valid script" sh -n "$SCRIPT"
check "the channels are read back" test "$(curl -s $H/alerts | jq -r '[.channels[].kind] | join(",")')" = "email,email,ntfy,discord,telegram"
check "with their fields" test "$(curl -s $H/alerts | jq -r '.channels[4].chat + " " + .channels[2].url')" = "-100200 https://ntfy.lab/topic-1"
# the web channels, with a stand-in of curl that notes what it was asked
mkdir -p $STAND/bin; : > $STAND/curl.log
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in @*) printf "[%%s] " "$(cat "${a#@}")";; *) printf "%%s " "$a";; esac; done >> %s/curl.log\necho >> %s/curl.log\n' $STAND $STAND > $STAND/bin/curl
chmod 755 $STAND/bin/curl
echo "the text of the report" | PATH=$STAND/bin:$PATH "$SCRIPT" "A subject" high warning
check "run by hand it reaches the two addresses by mail" test "$(grep -c '^Subject: A subject$' $STAND/mail/anna@lab $STAND/mail/bob@lab | cut -d: -f2 | tr '\n' ' ')" = "1 1 "
check "every one gets the whole text" test "$(grep -c '^the text of the report$' $STAND/mail/anna@lab $STAND/mail/bob@lab | cut -d: -f2 | tr '\n' ' ')" = "1 1 "
check "ntfy gets the title, the priority and the text" grep -q -- "-H Title: A subject -H Priority: high -H Tags: warning --data-binary \[the text of the report\] https://ntfy.lab/topic-1" $STAND/curl.log
check "Discord gets the subject" grep -qF -- '-d {"content": "A subject"} https://discord.lab/api/webhooks/1/abc' $STAND/curl.log
check "Telegram gets the chat and the text" grep -q -- "chat_id=-100200 --data-urlencode text=A subject https://api.telegram.org/bot123:abc_DEF/sendMessage" $STAND/curl.log
printf '#!/bin/sh\nexit 22\n' > $STAND/bin/curl
echo "x" | PATH=$STAND/bin:$PATH "$SCRIPT" "Second" high warning
check "a channel that fails makes the script fail" test $? != 0
check "and the others are still reached" grep -q '^Subject: Second$' $STAND/mail/bob@lab
# through the daemon: the report of a run goes to both addresses
post alerts_save '{"channels":"kind=email\tto=anna@lab\nkind=email\tto=bob@lab"}'
OLD=$(curl -s $U/config | jq -c '{notify_result, notify_result_level}')
rm -f $STAND/mail/*
req PATCH $U/config "$(jq -nc --arg c "$(echo "$BODY" | jq -r .command)" '{notify_result: $c, notify_result_level: "info"}')"; expect "the daemon takes the command" 200
req POST $U/maintenance '{}'; tasks_wait
check "the report of a run reaches the first address" grep -q '^Subject: \[INFO\] SnapRAID Maintenance' $STAND/mail/anna@lab
check "and the second, with the same text" cmp -s $STAND/mail/anna@lab $STAND/mail/bob@lab
check "the text is the report" grep -qiE "sync|scrub" $STAND/mail/bob@lab
req PATCH $U/config "$OLD"
post alerts_save '{"channels":""}';                  expect "without channels the script is removed" 202
refute "it is gone" test -e "$SCRIPT"
check "and no command is given" test "$(echo "$BODY" | jq -r .command)" = ""

section "update when enough files changed"
post settings '{"sync_changes_minutes":"0"}';        expect "the minutes between two looks have limits" 400 "1 to 1440"
if [ "${LAB_TEST_SLOW:-1}" != 0 ]; then
    tasks_wait
    post settings '{"sync_changes":"1000","sync_changes_minutes":"1"}'; expect "the limit is saved" 202
    SYNC=$(last_task sync .number); DIFF=$(last_task diff '.number // 0')
    mkdir -p $POOL/Changes
    for i in 1 2 3; do echo "few $i" > $POOL/Changes/few-$i.txt; done
    wait_for 200 test "$(last_task diff '.number // 0')" != "$DIFF"; tasks_wait
    check "the changes are looked for by the daemon" test "$(last_task diff '.number // 0')" != "$DIFF"
    sleep 70; tasks_wait
    check "few changes do not start an update" test "$(last_task sync .number)" = "$SYNC"
    post settings '{"sync_changes":"8"}'
    for i in $(seq 1 9); do echo "many $i" > $POOL/Changes/many-$i.txt; done
    wait_for 260 test "$(last_task sync .number)" != "$SYNC"; tasks_wait
    check "enough changes start it" test "$(last_task sync .number)" != "$SYNC"
    check "it is the automatic maintenance, with its safety limits" test "$(last_task sync .high_command)" = maintenance
    check "the new files are protected" test "$(curl -s $U/state | jq -r '(.diff_added // 0) + (.diff_updated // 0)')" = 0
    post settings '{"sync_changes":"","sync_changes_minutes":""}'
    SYNC=$(last_task sync .number); DIFF=$(last_task diff .number)
    echo "after" > $POOL/Changes/after.txt
    sleep 130
    check "turned off, the daemon does not look any more" test "$(last_task diff .number) $(last_task sync .number)" = "$DIFF $SYNC"
    rm -rf $POOL/Changes
    req POST $U/maintenance '{}'; tasks_wait
else
    skip "the update started by the changes" "LAB_TEST_SLOW=0"
    post settings '{"sync_changes":"","sync_changes_minutes":""}'
fi

section "space of the arrays and when it gets full"
SP=$(curl -s $H/space)
check "every array of the lab is measured" test "$(echo "$SP" | jq -r '.arrays | length')" -ge 3
check "used and total are sizes of the data disks" test "$(echo "$SP" | jq -r '[.arrays[] | select(.total_bytes > 0 and .used_bytes <= .total_bytes)] | length')" = "$(echo "$SP" | jq -r '.arrays | length')"
check "all of them are summed up" test "$(echo "$SP" | jq -r '.all.total_bytes == ([.arrays[].total_bytes] | add)')" = true
check "the samples are a file next to the settings" grep -qP "^\d+\tdefault\t\d+\t\d+$" "$CONFDIR/snapraidd-space.log"
check "the made-up days of the showcase give a forecast" test "$(echo "$SP" | jq -r '.all.forecast')" = true
check "growing, it says when it is full" test "$(echo "$SP" | jq -r '(.all.growth_bytes_per_day > 0) and (.all.days_to_full > 0)')" = true
check "the days of an array are given, the oldest first" test "$(echo "$SP" | jq -r '.arrays[0].days | (length > 7) and (.[0].day < .[-1].day)')" = true
LINES=$(grep -vc '^#' "$CONFDIR/snapraidd-space.log")
curl -s $H/space > /dev/null
check "one sample a day: asking again adds nothing" test "$(grep -vc '^#' "$CONFDIR/snapraidd-space.log")" = "$LINES"
check "today has one line for every array" test "$(awk -v d=$(curl -s "$H/space?days=1" | jq -r '[.arrays[].days[-1].day] | max') '$1 == d' "$CONFDIR/snapraidd-space.log" | wc -l)" -ge 3
check "fewer days can be asked" test "$(curl -s "$H/space?days=3" | jq -r '[.arrays[].days | length] | max')" -le 4

section "events of the machine"
EV=$(curl -s "$H/events?limit=500")
kinds=$(echo "$EV" | jq -r '[.events[].kind] | unique | join(" ")')
for k in power_cut power_back power_shutdown usb_open usb_eject burnin; do
    check "the event $k is recorded" grep -qw "$k" <<< "$kinds"
done
check "a power cut says how charged the battery was" test "$(echo "$EV" | jq -r '[.events[] | select(.kind == "power_cut")][-1].text')" = "Running on the battery of the UPS, 80% charged"
check "the newest is first" test "$(echo "$EV" | jq -r '(.events[0].at >= .events[-1].at)')" = true
check "the shutdown on battery is a dry run in the lab" grep -q "dry run" <<< "$(echo "$EV" | jq -r '[.events[] | select(.kind == "power_shutdown")][0].text')"
check "a limit is kept" test "$(curl -s "$H/events?limit=2" | jq -r '.events | length')" = 2
check "the events are a file next to the settings" grep -qP "^\d+\twarn\tpower_cut\tnut:labups\t" "$CONFDIR/snapraidd-events.log"
refute "a folder size is not an event" grep -qP "\tusage\t" "$CONFDIR/snapraidd-events.log"

section "the lab as it was"
# the tests take long: the disks of the other arrays may have gone to sleep, and a sleeping disk tells no health
for a in $(curl -s $U/arrays | jq -r '.arrays[].name'); do req POST $U/arrays/$a/refresh '{}'; done
for _ in $(seq 1 90); do
    [ "$(curl -s $U/arrays | jq -r '[.arrays[] | select(.health != "passed")] | length')" = 0 ] && break
    sleep 1
done
check "every array is healthy after the tests" test "$(curl -s $U/arrays | jq -r '[.arrays[] | select(.health != "passed")] | length')" = 0

echo
echo "extras tests: $PASS ok, $FAILS failed, $SKIP skipped"
exit $FAILS
