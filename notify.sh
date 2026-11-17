#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Stands for the mail, ntfy or webhook command of 'notify_start', 'notify_result' and
# 'notify_heartbeat' of SnapRAID Daemon: what the daemon would send is kept as a file in
# /lab/notify/inbox. Read them with `lab inbox`.
#   notify.sh start SUBJECT LEVEL TASK | notify.sh result SUBJECT LEVEL TASK CODE | notify.sh heartbeat
LAB=${LAB_DIR:-/lab}
mkdir -p "$LAB/notify/inbox"
kind=${1:-result}
f="$LAB/notify/inbox/$(date '+%Y%m%d-%H%M%S')-$$-$kind.txt"
{
    echo "Kind: $kind"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    [ -n "${SNAPRAID_ARRAY:-}" ] && echo "Array: $SNAPRAID_ARRAY"
    if [ "$kind" = heartbeat ]; then
        echo "Subject: the maintenance ended well"
    else
        echo "Subject: ${2:-}"
        echo "Level: ${3:-}"
        echo "Task: ${4:-}"
        [ -n "${5:-}" ] && echo "Exit code: $5"
        echo
        cat    # the report, as the daemon pipes it in
    fi
} > "$f"
exit 0
