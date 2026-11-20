#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Puts the showcase lab in the state of the pictures of the pages for everyday use
# (shots-everyday.json): run it inside the lab (docker exec -it snapraid-lab bash), then
#     node docs/tools/shots.mjs docs/tools/shots-everyday.json
H=http://127.0.0.1:7627/snapraid/v1/host
post() { curl -s -X POST -H 'Content-Type: application/json' --data-binary "$2" "$H/$1" > /dev/null; }
serial() { curl -s http://127.0.0.1:7627/snapraid/v2/disks | jq -r "[.data_disks[], .parity_disks[]] | .[] | select(.name==\"$1\") | .devices[0].serial"; }

# a share for everybody, one for a person, and the person
post share_user_set '{"user":"anna","password":"anna-lab"}'
post share_save '{"name":"Movies","path":"/mnt/storage/Movies","smb":true,"guest":true,"writable":false,"recycle":false,"comment":"Films for the TV"}'
post share_save '{"name":"Documents","path":"/mnt/storage/Documents","smb":true,"users":"anna","writable":true,"recycle":true,"recycle_days":"30"}'
# a backup of the photos to the USB disk, run once
uuid=$(blkid -s UUID -o value "$(findmnt -no SOURCE /mnt/lab/u1)")
post backup_save "{\"name\":\"Photos\",\"source\":\"/mnt/storage/Photos\",\"dest_uuid\":\"$uuid\",\"dest_dir\":\"Backups/Photos\",\"plug\":true,\"when\":\"Sun 05:00\"}"
post backup_run '{"name":"Photos"}'
sleep 5
# the disks of the default array in their bays, a short self-test, the automatic tests
bays="{\"rows\":2,\"cols\":4,\"slots\":{\"$(serial d1)\":0,\"$(serial d2)\":1,\"$(serial d3)\":2,\"$(serial d4)\":3,\"$(serial parity)\":4,\"$(serial 2-parity)\":5}}"
post settings "$(jq -n --arg b "$bays" '{"doc.bays": $b, "smart_short": "Sun 03:30", "smart_long": "Sat#1 04:30", "dircache": "1"}')"
post smart_test "{\"device\":\"$(readlink -f "$(findmnt -no SOURCE /mnt/lab/d1)" | sed 's/p[0-9]*$//')\",\"kind\":\"short\"}"
# files deleted, and the maintenance that stops for the OK
lab delete d2 55 > /dev/null
curl -s -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:7627/snapraid/v1/maintenance > /dev/null
sleep 30
echo "ready for the pictures"
