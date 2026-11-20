#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Puts the showcase lab in the state of the pictures of the fast disk, of the move of the parity
# and of the advanced mode (shots-tiers.json): run it inside the lab
# (docker exec -it snapraid-lab bash), then
#     node docs/tools/shots.mjs docs/tools/shots-tiers.json
U=http://127.0.0.1:7627/snapraid/v1
post() { curl -s -X POST -H 'Content-Type: application/json' --data-binary "$2" "$U/$1" > /dev/null; }
serial() { curl -s http://127.0.0.1:7627/snapraid/v2/disks | jq -r "[.data_disks[], .parity_disks[]] | .[] | select(.name==\"$1\") | .devices[0].serial"; }
job_wait() { for _ in $(seq 1 300); do [ "$(curl -s $U/storage/job | jq -r .job.running)" = false ] && return; sleep 1; done; }

# the blank USB disk s2 becomes the fast disk of the pool of the default array
for f in /run/lab/map/*; do [ "$(cat "$f")" = s2 ] && dev=/dev/$(basename "$f"); done
post storage/format "{\"device\":\"$dev\",\"fstype\":\"ext4\",\"label\":\"cache\",\"purpose\":\"data\",\"wipe\":false}"
job_wait
uuid=$(curl -s $U/storage/job | jq -r .job.uuid)
post storage/mount "{\"source\":\"UUID=$uuid\",\"target\":\"/mnt/lab/cache\",\"fstype\":\"ext4\",\"options\":\"defaults,noatime,nofail\",\"persist\":true}"
opts=$(curl -s $U/storage | jq -r '.pools[] | select(.mountpoint == "/mnt/storage") | .fstab_options' | sed 's/category.create=[a-z]*/category.create=ff/')
post storage/pool "{\"mountpoint\":\"/mnt/storage\",\"branches\":\"/mnt/lab/cache:/mnt/lab/d1:/mnt/lab/d2:/mnt/lab/d3:/mnt/lab/d4\",\"options\":\"$opts\",\"persist\":true}"
post host/cache_save '{"name":"cache","pool":"/mnt/storage","branch":"/mnt/lab/cache","age_hours":"0","fill":"70","when":"01:30","sync":true,"enabled":true,"policy":"pfrd"}'
# one move already done, then new files waiting on it
mkdir -p /mnt/storage/Incoming/holiday
for i in 1 2 3; do head -c 4000000 /dev/urandom > /mnt/storage/Incoming/holiday/clip-$i.mp4; done
find /mnt/lab/cache -type f -exec touch -d '30 minutes ago' {} +
post host/cache_run '{"name":"cache"}'
job_wait
sleep 20
for i in 4 5 6 7 8 9; do head -c 9000000 /dev/urandom > /mnt/storage/Incoming/holiday/clip-$i.mp4; done
# the disks of the default array in their bays
bays="{\"rows\":2,\"cols\":4,\"slots\":{\"$(serial d1)\":0,\"$(serial d2)\":1,\"$(serial d3)\":2,\"$(serial d4)\":3,\"$(serial parity)\":4,\"$(serial 2-parity)\":5}}"
post host/settings "$(jq -n --arg b "$bays" '{"doc.bays": $b, "sync_ratio": "2"}')"
echo "ready for the pictures"
