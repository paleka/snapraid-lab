#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Puts the showcase lab in the state of the pictures of the write test, the record of the runs,
# the UPS, the USB disk, the other computers and the alerts (shots-extras.json): run it inside
# the lab (docker exec -it snapraid-lab bash), then
#     node docs/tools/shots.mjs docs/tools/shots-extras.json
# The lab has no UPS, no other computer and no mail: it writes stand-ins of upsc, mount.cifs and
# mail, like tests/extras-test.sh does, and leaves them in place for the pictures.
U=http://127.0.0.1:7627/snapraid/v1
post() { curl -s -X POST -H 'Content-Type: application/json' --data-binary "$2" "$U/$1" > /dev/null; }
tasks_wait() {
    sleep 2
    for _ in $(seq 1 600); do
        [ "$(curl -s "$U/tasks?limit_history=0&limit_messages=0" | jq '(.active | length) + (.pending | length)')" = 0 ] && return 0
        sleep 1
    done
}
STAND=/run/lab/standins
mkdir -p $STAND/ups $STAND/smb/Users/anna/Pictures/2025 $STAND/smb/Users/anna/Documents
echo "a picture" > $STAND/smb/Users/anna/Pictures/2025/beach.jpg
echo "a letter" > $STAND/smb/Users/anna/Documents/letter.txt
cat > /usr/local/bin/upsc <<EOS
#!/bin/sh
[ "\$1" = "-l" ] && { echo eaton; exit 0; }
[ "\$1" = "eaton" ] || { echo "Error: Unknown UPS" >&2; exit 1; }
cat $STAND/ups/state
EOS
printf 'battery.charge: 100\nbattery.runtime: 2280\nups.status: OL\n' > $STAND/ups/state
cat > /sbin/mount.cifs <<EOS
#!/bin/sh
src=\$1; dst=\$2
dir=$STAND/smb/\${src#//anna-pc/}
[ -d "\$dir" ] || { echo "mount error(2): No such file or directory" >&2; exit 32; }
mount --bind "\$dir" "\$dst" && mount -o remount,bind,ro "\$dst"
EOS
chmod 755 /usr/local/bin/upsc /sbin/mount.cifs

# the UPS, the computer of Anna and a backup of her pictures
post host/settings '{"ups":"nut:eaton","ups_shutdown":"1"}'
post host/remote_save '{"name":"anna-pc","kind":"smb","host":"anna-pc","share":"Users","user":"anna","password":"secret"}'
post host/backup_save '{"name":"anna-pictures","source":"/mnt/remote/anna-pc/anna/Pictures","dest_path":"/mnt/storage/Backups/anna-pc","when":"Sun 06:00","mirror":false,"enabled":true}'
post host/backup_run '{"name":"anna-pictures"}'
sleep 5

# two places for the alerts
post host/alerts_save '{"channels":"kind=ntfy\turl=https://ntfy.sh/home-server-x7q2\nkind=email\tto=robert@example.com"}'
cmd=$(curl -s $U/host/alerts | jq -r .script)
curl -s -X PATCH -H 'Content-Type: application/json' -d "{\"notify_result\":\"$cmd \\\"%s\\\" \\\"%n\\\" \\\"%t\\\"\"}" $U/config > /dev/null

# a run that finds damage, the repair, and a clean run
post maintenance '{}'; tasks_wait
f=$(find /mnt/lab/d1 -type f -size +64k ! -name 'snapraid.content*' | sort | head -1)
t=$(stat -c %y "$f"); head -c 4096 /dev/urandom | dd of="$f" bs=4096 seek=4 conv=notrunc status=none; touch -d "$t" "$f"
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
post schedule '{"tasks":[{"command":"scrub","args":["-p","100","-o","0"]}]}'; tasks_wait
post schedule '{"tasks":[{"command":"fix","args":["-e"]}]}'; tasks_wait
post maintenance '{}'; tasks_wait
sleep 65
