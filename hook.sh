#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# Example of 'hook_script' of SnapRAID Daemon: it is run before a task works on the array
# (task-begin) and after it (task-end, or task-error). A real one stops what writes to the
# disks, or takes a snapshot of a database. This one writes a line: read them with `lab hooks`.
# A task-begin that fails stops the task: try it with `lab hooks block`.
LAB=${LAB_DIR:-/lab}
mkdir -p "$LAB/notify"
echo "$(date '+%Y-%m-%d %H:%M:%S') ${SNAPRAID_ARRAY:-default} $1" >> "$LAB/notify/hooks.log"
if [ "$1" = task-begin ] && [ -f "$LAB/notify/block" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${SNAPRAID_ARRAY:-default} task-begin refused (lab hooks block)" >> "$LAB/notify/hooks.log"
    exit 1
fi
exit 0
