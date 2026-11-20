# SnapRAID lab

A Docker lab with emulated disks, to try and to test what the
[`storage` branch of paleka/snapraid-daemon](https://github.com/paleka/snapraid-daemon/tree/storage)
adds to SnapRAID Daemon: the **Storage** and **Arrays** pages, the **pages for everyday use**
(Home, My files, Sharing, Backups, Disks, Protection, Alerts, System, Help) and the settings of
the machine behind them.

Out of the box it is a showcase: three arrays in one daemon, four mergerfs pools, eighteen disks
of different sizes, kinds (HDD, shingled HDD, SAS, SATA SSD, NVMe, USB) and filesystems (ext4,
XFS, Btrfs), and configurations that use most options of SnapRAID and of its daemon. See
[The showcase lab](#the-showcase-lab).

## Whose work is what

| Project | Author | Where |
|---|---|---|
| SnapRAID, the engine | Andrea Mazzoleni | <https://github.com/amadvance/snapraid>, <https://www.snapraid.it/> |
| SnapRAID Daemon and its web UI | Andrea Mazzoleni | <https://github.com/amadvance/snapraid-daemon>, <https://www.snapraid.it/ui> |
| Storage, Arrays and everyday pages (fork of the daemon) | Robert Paleka | <https://github.com/paleka/snapraid-daemon/tree/storage>, see its `CHANGES-FORK` |
| This lab | Robert Paleka | this repository |

The fork and this lab are unofficial: they are not part of SnapRAID and are not reviewed or
endorsed by its author. Report problems with them in these two repositories, not to the SnapRAID
project. For SnapRAID itself see its [manual](https://www.snapraid.it/manual) and its
[support page](https://www.snapraid.it/support).

The lab and the fork were written with the help of an AI coding assistant (Claude).

## Screenshots

### Quiet, the default look

Tiles of different sizes, one blue accent, the status always in words. Light or dark follows the
computer. Taken from the showcase lab after one update and check of every array, two shares and
two backups. The pictures further down are of Commander, the original look, with the same pages.

| | |
|---|---|
| **Home**: is it safe, with the one thing to do; the last 14 days; space with when it gets full; disks, checks, what comes next, backups, shares, what happened<br>[![Home](docs/screenshots/quiet-home.png)](docs/screenshots/quiet-home.png) | **Home in the dark**: the same, following the computer<br>[![Home, dark](docs/screenshots/quiet-home-dark.png)](docs/screenshots/quiet-home-dark.png) |
| **Disks**: a click on a bay shows that disk, its facts and what can be done<br>[![Disks](docs/screenshots/quiet-disks.png)](docs/screenshots/quiet-disks.png) | **Protection**: the rules in plain words, how long ago each part was checked, the past runs<br>[![Protection](docs/screenshots/quiet-protection.png)](docs/screenshots/quiet-protection.png) |
| **Search** (Ctrl K): pages, disks, shares, backups, settings<br>[![Search](docs/screenshots/quiet-search.png)](docs/screenshots/quiet-search.png) | **Phone**<br>[![Phone](docs/screenshots/quiet-phone.png)](docs/screenshots/quiet-phone.png) |

### The pages for everyday use

The menu starts with the pages for people who are not technical; the detailed pages of the daemon
are under **Advanced**. Taken from the showcase lab after `lab scenario mass-delete`, so Home has
something to say.

| | |
|---|---|
| **Home**: one headline saying if the files are safe, with the one thing to do, then what needs attention and what happened lately<br>[![Home](docs/screenshots/everyday-home.png)](docs/screenshots/everyday-home.png) | **Protection**: when it runs, how much is checked, the safety check, and how long every run took<br>[![Protection](docs/screenshots/everyday-protection.png)](docs/screenshots/everyday-protection.png) |
| **My files**: the pool, with the disk of every file; check for damage, get deleted files back, copy, rename, delete<br>[![My files](docs/screenshots/everyday-files.png)](docs/screenshots/everyday-files.png) | **Get back deleted files**: what can still be rebuilt, chosen file by file<br>[![Get back deleted files](docs/screenshots/everyday-restore.png)](docs/screenshots/everyday-restore.png) |
| **Disks**: a picture of the case with the bay of every disk, health, temperature, self-tests, power settings<br>[![Disks](docs/screenshots/everyday-disks.png)](docs/screenshots/everyday-disks.png) | **Sharing**: shared folders with the address to open them, and the people who can<br>[![Sharing](docs/screenshots/everyday-sharing.png)](docs/screenshots/everyday-sharing.png) |
| **Share a folder**: who can open it, read only or not, recycle bin<br>[![Share a folder](docs/screenshots/everyday-share-dialog.png)](docs/screenshots/everyday-share-dialog.png) | **Backups**: copies to a USB disk, on a schedule or when it's plugged in<br>[![Backups](docs/screenshots/everyday-backups.png)](docs/screenshots/everyday-backups.png) |
| **Alerts**: where to send a message when something goes wrong<br>[![Alerts](docs/screenshots/everyday-alerts.png)](docs/screenshots/everyday-alerts.png) | **System**: power, the backup of the settings, diagnostics<br>[![System](docs/screenshots/everyday-system.png)](docs/screenshots/everyday-system.png) |

### A fast disk, a larger parity, and the advanced mode

Every page for everyday use shows the usual choices; its **Advanced** switch shows the finer
ones, and is remembered page by page. Taken from the showcase lab after
`docs/tools/tiers-prepare.sh`, which makes the blank USB disk the fast disk of the pool.

| | |
|---|---|
| **Disks, with Advanced on**: every disk also offers what applies to it among power settings, what uses it, copy, empty, and the move of the parity<br>[![Disks, with Advanced on](docs/screenshots/tiers-disks-advanced.png)](docs/screenshots/tiers-disks-advanced.png) | **Fast disk**: an SSD in front of the pool: how much waits on it, that it is not protected until moved, and when it is moved<br>[![Fast disk](docs/screenshots/tiers-fast-disk.png)](docs/screenshots/tiers-fast-disk.png) |
| **Fast disk, its settings**: the time of the move; with Advanced also the age of the files to leave, the fill level and the sync after<br>[![Fast disk, its settings](docs/screenshots/tiers-fast-disk-edit.png)](docs/screenshots/tiers-fast-disk-edit.png) | **The parity on a larger disk**: copied, checked byte by byte, then the array is switched to it; the old parity disk becomes a data disk<br>[![The parity on a larger disk](docs/screenshots/tiers-parity-move.png)](docs/screenshots/tiers-parity-move.png) |
| **Replace by copying**: when the old disk still reads, its files go straight to the new one<br>[![Replace by copying](docs/screenshots/tiers-replace-copy.png)](docs/screenshots/tiers-replace-copy.png) | **Protection, with Advanced on**: going on after a big tidy up, reading new files twice, stopping on files become empty<br>[![Protection, with Advanced on](docs/screenshots/tiers-protection-advanced.png)](docs/screenshots/tiers-protection-advanced.png) |
| **My files, with Advanced on**: the size of a folder and the disks it lives on<br>[![My files, with Advanced on](docs/screenshots/tiers-files-advanced.png)](docs/screenshots/tiers-files-advanced.png) | **The disks of a folder**: where it is now, where it should live, and if it is kept there for the files to come<br>[![The disks of a folder](docs/screenshots/tiers-folder-move.png)](docs/screenshots/tiers-folder-move.png) |
| **Size of a folder**: how much of it is on every disk<br>[![Size of a folder](docs/screenshots/tiers-folder-size.png)](docs/screenshots/tiers-folder-size.png) | **The tour of the first visit**: five short steps, also in Help<br>[![The tour of the first visit](docs/screenshots/tiers-tour.png)](docs/screenshots/tiers-tour.png) |
| **Empty a disk**: its files go to the other disks, then one click takes it out of the array<br>[![Empty a disk](docs/screenshots/tiers-empty-remove.png)](docs/screenshots/tiers-empty-remove.png) | **Adding a disk larger than the parity**: the Add dialog offers to make it the parity<br>[![Adding a disk larger than the parity](docs/screenshots/tiers-add-parity-tip.png)](docs/screenshots/tiers-add-parity-tip.png) |
| **One file of a split parity to a larger disk**<br>[![One file of a split parity](docs/screenshots/tiers-parity-split.png)](docs/screenshots/tiers-parity-split.png) | |

### Tests of new disks, a power cut, USB disks, other computers

Taken from the showcase lab after `docs/tools/extras-prepare.sh`, which sets a stand-in UPS, a
stand-in computer with a shared folder and a backup of it, two places for the alerts, and a scrub
that finds damage followed by its repair.

| | |
|---|---|
| **Test of a new disk**: every block written and read back before it holds files; it asks for the name of the disk, since it erases it<br>[![Test of a new disk](docs/screenshots/extras-write-test.png)](docs/screenshots/extras-write-test.png) | **A USB disk**: Eject finishes the writes and releases it; Open makes its files reachable until ejected, without a line in fstab<br>[![A USB disk](docs/screenshots/extras-disks-usb.png)](docs/screenshots/extras-disks-usb.png) |
| **Eject**: what happens, and what does not change<br>[![Eject](docs/screenshots/extras-usb-eject.png)](docs/screenshots/extras-usb-eject.png) | **Past runs**: every update and check with the damage found and what was repaired, kept on disk<br>[![Past runs](docs/screenshots/extras-runs.png)](docs/screenshots/extras-runs.png) |
| **Protection, with Advanced on**: also update as soon as enough files changed<br>[![Protection, with Advanced on](docs/screenshots/extras-protection-advanced.png)](docs/screenshots/extras-protection-advanced.png) | **Power cut**: the UPS, its charge, and the shutdown before the battery is empty; with Advanced the charge and the minutes<br>[![Power cut](docs/screenshots/extras-ups.png)](docs/screenshots/extras-ups.png) |
| **Other computers**: shared folders of a PC, a Mac or a NAS, copied here by a backup<br>[![Other computers](docs/screenshots/extras-other-computers.png)](docs/screenshots/extras-other-computers.png) | **Add another computer**: its name, the shared folder, the user; the password kept apart, for root only<br>[![Add another computer](docs/screenshots/extras-remote-edit.png)](docs/screenshots/extras-remote-edit.png) |
| **A backup from another computer**: a folder of it, into a folder of this server, on a schedule<br>[![A backup from another computer](docs/screenshots/extras-backup-from-computer.png)](docs/screenshots/extras-backup-from-computer.png) | **Alerts to more places**: a phone and an email, every message to all of them<br>[![Alerts to more places](docs/screenshots/extras-alerts.png)](docs/screenshots/extras-alerts.png) |

### The Storage and Arrays pages

![Tour of the Storage and Arrays pages](docs/screenshots/tour.gif)

The Storage and Arrays pages inside SnapRAID Commander, the web UI of SnapRAID Daemon by Andrea
Mazzoleni. Everything outside those two pages, and the look of the UI, is his work. The pictures
are all taken from this lab as `docker compose up --build` makes it: the disks are loop devices
of a few hundred MB, described to SnapRAID and to the UI as the disks of the table in
[The showcase lab](#the-showcase-lab).

| | |
|---|---|
| **Arrays**: three arrays in one daemon, the four pools, and what protects every disk<br>[![Arrays](docs/screenshots/arrays.png)](docs/screenshots/arrays.png) | **Overview**: the default array, its pool and the advisor; the blank spares and the disks that are in no array are on the right<br>[![Overview](docs/screenshots/overview.png)](docs/screenshots/overview.png) |
| **Array & disks**: every disk the machine sees, with model, serial, kind, size and filesystem<br>[![Array & disks](docs/screenshots/array-and-disks.png)](docs/screenshots/array-and-disks.png) | **Kinds of disk**: HDD, SAS and SSD in one array, and two disks outside it that are watched all the same (`extra`)<br>[![Kinds of disk](docs/screenshots/showcase-disks.png)](docs/screenshots/showcase-disks.png) |
| **An array of flash disks**: NVMe and SSD, with their wear in place of the failure probability<br>[![An array of flash disks](docs/screenshots/showcase-disks-flash.png)](docs/screenshots/showcase-disks-flash.png) | **A split parity**: one parity level over two disks: the first is full, the second holds the rest<br>[![A split parity](docs/screenshots/showcase-split-parity.png)](docs/screenshots/showcase-split-parity.png) |
| **Storage of another array**: the sidebar chooses the array; this one places new files next to their folder, and the advisor says what that means<br>[![Storage of another array](docs/screenshots/arrays-storage.png)](docs/screenshots/arrays-storage.png) | **Pool**: the pools of the machine with branches, protection, placement policy and balance<br>[![Pool](docs/screenshots/pool.png)](docs/screenshots/pool.png) |
| **Configuration**: the SnapRAID configuration as a form, or as text for the options the form does not have<br>[![Configuration](docs/screenshots/configuration.png)](docs/screenshots/configuration.png) | **Options of an array**: every array has its own schedule, thresholds, scrub plan, spin down, hook and notifications<br>[![Options of an array](docs/screenshots/showcase-settings.png)](docs/screenshots/showcase-settings.png) |
| **Guided setup, 1**: choose the disks and their role; every disk comes with model and serial<br>[![Guided setup, 1](docs/screenshots/setup-1-disks.png)](docs/screenshots/setup-1-disks.png) | **Guided setup, 2**: filesystem, mount points, pool and its policy<br>[![Guided setup, 2](docs/screenshots/setup-2-options.png)](docs/screenshots/setup-2-options.png) |
| **Guided setup, 3**: what is going to be done, in order, before anything is erased<br>[![Guided setup, 3](docs/screenshots/setup-3-review.png)](docs/screenshots/setup-3-review.png) | **Create a pool**: any set of mounted disks; the ones without parity are marked<br>[![Create a pool](docs/screenshots/pool-create.png)](docs/screenshots/pool-create.png) |
| **Replace a disk**: the steps, a warning when the new disk is larger than the parity, and the confirmation to type<br>[![Replace a disk](docs/screenshots/replace-disk.png)](docs/screenshots/replace-disk.png) | **Balance**: what happens and what does not change<br>[![Balance](docs/screenshots/balance.png)](docs/screenshots/balance.png) |
| **Degraded array**: a disk came back empty: maintenance is suspended and the advisor offers the recovery<br>[![Degraded array](docs/screenshots/degraded.png)](docs/screenshots/degraded.png) | **Recover**: choose the lost disks; fix, check and sync in one command<br>[![Recover](docs/screenshots/recover.png)](docs/screenshots/recover.png) |
| **Recovery in the Tasks page**: every step with its result<br>[![Recovery in the Tasks page](docs/screenshots/recover-tasks.png)](docs/screenshots/recover-tasks.png) | **Add an array**: a name, and optionally an existing SnapRAID configuration to take over<br>[![Add an array](docs/screenshots/arrays-add.png)](docs/screenshots/arrays-add.png) |
| **Move a disk to another array**: with its files, step by step, and when the disk has no parity<br>[![Move a disk to another array](docs/screenshots/arrays-move.png)](docs/screenshots/arrays-move.png) |  |

They are made with `docs/tools/shots.mjs` (Playwright and Chrome) from six states of the lab:
as it starts (`shots-ready.json`), after `lab scenario mass-delete` and a maintenance
(`shots-everyday.json`), after `docs/tools/tiers-prepare.sh` (`shots-tiers.json`), after
`docs/tools/extras-prepare.sh` (`shots-extras.json`), after
`lab scenario dead-disk` (`shots-degraded.json`), and started with `LAB_PRESET=blank`
(`shots-blank.json`).

## Versions

| What | Version |
|---|---|
| SnapRAID engine | release 15.1, unmodified, commit `4054832` (checked by the `Dockerfile`) |
| SnapRAID Daemon | the checkout next to this folder; all the tests last run with `storage` at `8914e17`, the pictures taken with `7250acd` |
| mergerfs, xfsprogs, btrfs-progs | the ones of Debian 12 |

## Start

Put the two checkouts side by side:

    git clone -b storage https://github.com/paleka/snapraid-daemon.git
    git clone https://github.com/paleka/snapraid-lab.git
    cd snapraid-lab
    docker compose up --build

Then open http://localhost:7627

A daemon checkout somewhere else: `DAEMON_SRC=/path/to/snapraid-daemon docker compose up --build`.
Docker Compose 2.17 or later is needed (`additional_contexts`).

Stop with Ctrl-C (or `docker compose down`). The arrays survive restarts.
`docker compose down -v` throws them away and the next start builds new ones.

The first start takes a minute or two: it writes about 2 GB of sample files and syncs the three
arrays. The disk images are sparse and take about 3 GB in the Docker volume.

To try the login of the daemon (`net_auth_credential`): `LAB_AUTH=lab:secret docker compose up --build`.

A small lab, one array of equal disks (4 data, 2 parity) with two blank spares, and nothing else:

    docker compose -f docker-compose.simple.yml up --build

## The showcase lab

`docker-compose.yml` describes it, and every line of it can be changed (then `docker compose down -v`,
so the lab is built again). `docker exec snapraid-lab lab disks` prints this table from the running lab.

| Disk | Array | Role | Kind | Size | Filesystem |
|---|---|---|---|---|---|
| `d1` | default | data | HDD 5400 rpm | 256 MB | ext4 |
| `d2` | default | data | shingled HDD (SMR) | 512 MB | XFS |
| `d3` | default | data | SAS HDD 7200 rpm, a few grown defects, runs hot | 768 MB | ext4 |
| `d4` | default | data | SATA SSD | 384 MB | Btrfs |
| `p1`, `p2` | default | parity, 2-parity | HDD | 1024 MB | ext4 |
| `s1` | none | blank spare, larger than the parity | HDD | 2048 MB | none |
| `s2` | none | blank spare, removable | USB HDD | 320 MB | none |
| `m1`, `m2` | media | data | HDD, shingled HDD | 1024, 768 MB | XFS |
| `q1`, `q2` | media | one parity level split over two disks | HDD | 256, 768 MB | ext4 |
| `f1`, `f2` | flash | data | NVMe | 384 MB | Btrfs |
| `f3` | flash | data | SATA SSD | 512 MB | Btrfs |
| `g1` | flash | parity | NVMe | 640 MB | ext4 |
| `x1` | none | mounted, pooled in `/mnt/scratch`, no parity | SATA SSD | 256 MB | ext4 |
| `u1` | none | mounted on its own, no parity | USB HDD | 512 MB | ext4 |

Four pools, each placing new files in a different way: `/mnt/storage` (default array, `pfrd`),
`/mnt/media` (`mfs`), `/mnt/flash` (`epmfs`, which the advisor of the Storage page has something
to say about) and `/mnt/scratch` (no parity).

What the three arrays show:

| Array | SnapRAID | Daemon |
|---|---|---|
| **default** | two parity levels; four content files; data disks of four sizes and three filesystems; `extra` (the two disks outside the array are watched by `smart` and `probe`); `nohidden` and several `exclude`; `blocksize` and `hashsize`; `temp_limit` and `temp_sleep`; `pool` (a folder of symbolic links, `/lab/links`); `smartctl` (custom options for the SAS and the USB disk); `smartignore`; `autosave` | two schedules (`02:00, Sun 05:00`); `sync_prehash`; `sync_prevent_truncations`; sync thresholds; spin down after `15, 30` minutes (data, parity); hook script; `notify_start`, `notify_result` at level `info`, `notify_heartbeat`; `array_parallel`; `sys_log_compression`; `sys_smartignore` |
| **media** | one parity level split over two disks, each smaller than the largest data disk: the first file is full and the second one in use | its own schedule (`Wed 03:00, Sat 03:00`), scrub plan (12%) and spin down (`15, 45`); notified only from `warning` up |
| **flash** | `snapshot`: a sync reads the Btrfs data disks from a snapshot, and what is changed or deleted afterwards stays recoverable until the next sync | twice a day; no sync threshold; full scrub at every run; no spin down |

The hook and the notification commands are two small scripts of the lab (`hook.sh`, `notify.sh`):
a real hook would stop a service, a real notification would be a mail or an ntfy message. Here
they write files, to be read with `lab hooks` and `lab inbox`.

Options of the daemon that are not set, because they do not fit a container: `sys_shutdown_on`,
`hook_docker_pause`, `hook_run_as_user`, `notify_run_as_user`, `notify_syslog_*`, `check_updates`.
More parity levels (up to six) are a matter of `LAB_PARITY_DISKS`.

Ready-made situations, to look at in the UI:

    docker exec snapraid-lab lab scenario                     # the list
    docker exec snapraid-lab lab scenario failing-disk        # a parity disk fails its SMART self-assessment
    docker exec snapraid-lab lab scenario worn-flash          # an NVMe disk at the end of its life
    docker exec snapraid-lab lab scenario heat                # a disk over temp_limit: sync and scrub stop and wait
    docker exec snapraid-lab lab scenario bit-rot             # silent corruption on two arrays
    docker exec snapraid-lab lab scenario mass-delete         # more deletions than the sync threshold allows
    docker exec snapraid-lab lab scenario dead-disk           # a data disk comes back empty, right after a sync
    docker exec snapraid-lab lab scenario dead-disk-unsynced  # the same, with changes not synced on the other disks
    docker exec snapraid-lab lab scenario dead-flash-disk     # the same accident on the array with snapshots
    docker exec snapraid-lab lab scenario two-dead-disks      # two data disks lost together
    docker exec snapraid-lab lab scenario unbalanced          # one disk of the pool much fuller than the others
    docker exec snapraid-lab lab scenario hook-refuses        # the hook stops the tasks before they start
    docker exec snapraid-lab lab scenario reset-smart         # every disk healthy again

`dead-disk-unsynced` and `dead-flash-disk` are the same accident on two arrays. In the default
array, files changed or deleted on the other disks after the last sync were needed to rebuild the
lost one, and some blocks may not be rebuilt: that is how SnapRAID works, and why a sync should
not wait. In the flash array the snapshots still hold those files, and everything comes back.

## Trying the Storage page

The lab starts with three working arrays plus two blank spare disks, so in **Storage** you can
add a disk, replace one and remove one, and in **Arrays** move a disk from an array to another.
The larger spare is bigger than the parity of the default array, the smaller one is a removable
USB disk: the dialogs have something to say about both.

To try the first-time setup instead, start from empty disks (eighteen of them, of every kind;
`docker-compose.simple.yml` takes `LAB_PRESET=blank` too, and gives eight equal ones):

    docker compose down -v
    LAB_PRESET=blank docker compose up --build

and use **Storage → Guided setup**. What the UI sets up (filesystems, `/etc/fstab`, the pool,
`snapraid.conf`) lives in the lab volume and is mounted again at the next start.

The daemon runs with `net_storage_admin = 1`, the option of the fork that lets the UI change
disks, mounts, pools and the SnapRAID configuration. It is off by default outside the lab.

More things to try there:

    docker exec snapraid-lab lab fill /mnt/lab/d1 150   # unbalance the pool, then Pool → Balance
    docker exec snapraid-lab lab dup /mnt/storage       # make duplicates, then Pool → Look for duplicates
    docker exec snapraid-lab lab scenario dead-disk     # a "replaced" disk: the array goes DEGRADED, then Overview → Recover

Storage administration also needs the daemon protected (loopback only, `net_auth_credential` or
`net_acl`). The lab uses a `net_acl` that lets in private addresses only, because requests arrive
from the Docker network. On a real machine prefer `net_auth_credential`.

## Tests

Three layers, from the fastest (the first two also cover more arrays: `test/ui/arrays.test.mjs`
and the layout tests of the selftest):

| What | Where | Run |
|---|---|---|
| Daemon selftest: validation of everything coming from the network, mount table parsing, fstab editing, pool helpers | fork, `daemon/storage.c` (`storage_selftest`) | `make check`, or `snapraidd test` |
| Logic of the Storage page: configuration parsing, disk states, guided setup rules, advisor | fork, `test/ui/storage.test.mjs` | `make check`, or `node --test test/ui/storage.test.mjs` |
| Storage API end to end, on the emulated disks: format, mount, fstab, pool, browse, duplicates, balance, recovery of a replaced disk, permissions | here, `tests/api-test.sh` | see below |

The first two run at every image build (a failure stops the build). The third formats disks,
so it has its own throwaway lab:

    docker compose -f docker-compose.test.yml up --build --abort-on-container-exit --exit-code-from tests
    docker compose -f docker-compose.test.yml down -v

It prints one line per check and exits with the number of failures.

`tests/multi-array-test.sh` covers more arrays in the same daemon, with five data disks, two
parity disks and a spare of 256 MB:

    docker compose -f docker-compose.arrays.yml up --build --abort-on-container-exit --exit-code-from tests
    docker compose -f docker-compose.arrays.yml down -v

It creates a second array and refuses the names, paths and configurations that would clash;
checks that a disk cannot end in two arrays, as data, parity or content; that every array has its
own tasks, logs, options and recovery; that a sync waits for the one of another array unless they
are allowed to run together, while a probe is never delayed; three pools with what protects every
branch, and a pool over two arrays; that a balance and a sync of the same disks keep away from
each other; arrays added and removed by hand with a reload, and from the API; a data disk moved
with its files to another array and rebuilt there; and both arrays back after a restart.

A fourth one, `tests/mixed-size-test.sh`, checks that disks of different sizes work as SnapRAID
promises, on data disks of 256, 512, 1024 and 384 MB with 1024 MB parity:

    docker compose -f docker-compose.sizes.yml up --build --abort-on-container-exit --exit-code-from tests
    docker compose -f docker-compose.sizes.yml down -v

It covers the loss of the largest and the smallest disk together, a parity level split over two
disks each smaller than the largest data disk, a pool balanced by fill level, a data disk replaced
by one larger than the parity, what happens when that disk then outgrows the parity (the sync stops
with the list of the files that do not fit, and what was synced before stays recoverable), and a
128 MB disk.

A fifth one, `tests/showcase-test.sh`, checks the showcase lab itself, on the disks and the
options of `docker-compose.yml` (stop the lab first: it uses the same port; it takes about seven
minutes, three of them waiting for a hot disk to cool down):

    docker compose -f docker-compose.showcase.yml up --build --abort-on-container-exit --exit-code-from tests
    docker compose -f docker-compose.showcase.yml down -v

It checks that SnapRAID and the daemon see every disk as its kind (interface, rotation, wear,
grown defects), with its size and filesystem; the pools and what protects them; the split parity
with both halves in use; that every option of the three configurations is accepted and does what
it says (hidden and excluded files, the folder of links, the custom `smartctl` options, prehash,
compressed logs); a maintenance of the three arrays with the hook called and the notifications
received; snapshots, and a disk lost with changes not synced rebuilt completely thanks to them;
a hook that refuses; disks going bad and good again; the temperature limit; and the login.

A sixth one, `tests/existing-setup-test.sh`, checks that the daemon is a drop in addition to a
machine where SnapRAID is already used from the command line. It builds no lab: it makes the
machine of a long time user (SnapRAID 12 of Debian, a `snapraid.conf` and an `/etc/fstab` written
by hand with comments, a mergerfs pool given with a pattern, a nightly cron job), runs the
installer of the fork on it, and compares everything before and after:

    docker compose -f docker-compose.existing.yml up --build --abort-on-container-exit --exit-code-from tests
    docker compose -f docker-compose.existing.yml down -v

It covers the content file of SnapRAID 13 and older, that SnapRAID 15 refuses, converted by the
installer without touching the parity; the installer stopping with nothing changed when the array
has changes not synced, when a sync of the owner is running, when a disk is not mounted, and when
the engine was built from the sources; the configuration, `/etc/fstab`, the cron job, the parity
and the data left as they were, timestamps included; the daemon starting without a schedule and
without spin down; `snapraid` diff, sync, fix, scrub and check from the shell while the daemon
runs, and the daemon noticing them; a command of the daemon giving way when the shell holds the
array; a save from the web UI keeping comments and the owner's own `.bak`; a change of the pool
that does not remount it; and the package removed with everything as before. The packages are for
x86-64, so on Apple silicon this image is built and run emulated, and it needs the network.

A seventh one, `tests/machine-test.sh`, checks the settings of the machine behind the pages for
everyday use, on the showcase lab (stop the lab first; about five minutes, two of them waiting for
a USB disk "plugged in" again):

    docker compose -f docker-compose.machine.yml up --build --abort-on-container-exit --exit-code-from tests
    docker compose -f docker-compose.machine.yml down -v

It covers the validation of every setting; the folder cache; SMB shares written for Samba and
accepted by `testparm`, their users and recycle bin, NFS exports; the reset of permissions;
renames and deletes, with mount points and paths climbing out refused; copies; backups to the USB
disk `u1`, with and without mirror, of the disk not mounted (mounted for the run and released),
and started by plugging the disk in; the wipe of the blank disk `s2`, refused for disks of an
array, mounted disks and partitions; the programs keeping a disk busy; SMART self-tests and their
log; power settings refused by a disk; diagnostics without serial numbers and secrets; and the
backup and restore of the settings. In the lab the daemon only logs the idle action
(`SNAPRAIDD_HOST_DRYRUN=1`): the container must not suspend the machine.

An eighth one, `tests/tiers-test.sh`, checks the moves of files among the disks of a pool and
the move of the parity, on the showcase lab (stop the lab first; about five minutes, three of
them waiting for the daemon to run a sync again by itself):

    docker compose -f docker-compose.tiers.yml up --build --abort-on-container-exit --exit-code-from tests
    docker compose -f docker-compose.tiers.yml down -v

It covers a folder brought to a chosen disk and a disk emptied to the others, with the pool
showing the same files with the same data before and after, the files with a twin on another
disk left and named, a path climbing out or going through a link refused, and the sync that asks
when a disk was emptied; the blank disk `s2` as fast disk in front of the pool: new files landing
on it, the mover bringing them to the array and running the maintenance, a file just written left
for the next time, a folder set to stay on the fast disk left there; a folder kept on chosen
disks: brought to one disk, a new file taken there by the mover, a file landed elsewhere brought
back, a second folder on two disks; the parity copied to the blank disk `s1`, the same as the
original, with the old one untouched, a full scrub against the copy, and a deleted file rebuilt
from it; one file of the split parity of the `media` array moved to another disk, with the sync
and a full scrub after; a disk too small and a pool refused; the size of a folder disk by disk; the reading test
of a whole disk; the copy of a single file; and a sync stopped by the limit of the deleted files
run again by the daemon when many more files were added, and not when few were.

A ninth one, `tests/extras-test.sh`, checks the write test of a new disk, the record of the runs,
the battery backup (UPS), the disks opened and ejected, the folders of other computers and the
alerts to more places at once, on the showcase lab (stop the lab first; about fifteen minutes,
most of them waiting for the daemon to look for changes by itself):

    docker compose -f docker-compose.extras.yml up --build --abort-on-container-exit --exit-code-from tests
    docker compose -f docker-compose.extras.yml down -v

The lab has no UPS, no other computer and no mail, so the test writes small stand-ins of `upsc`,
`mount.cifs` and `mail` for its time, and removes them at the end. It covers the blank disk `s2`
written and read back whole, left blank, with disks of an array refused; a sync and a scrub in
the record, silent damage written into a protected file found by a scrub and recorded with its
errors, the repair recorded with what it recovered, and every run recorded once; a power cut
seen, the scrub running then stopped and recorded as stopped, the shutdown (only logged in the
lab) below the chosen charge, below the minutes left and when the UPS says the battery is low,
never on one read alone nor with the shutdown turned off, and a UPS that stops answering not
taken as a power cut; the USB disk `u1` ejected, refused while a file on it is open, opened under
`/media` without a line in fstab and ejected from one of its partitions, with the disk of a pool
refused; a folder of another computer saved with its password apart, a wrong password, a missing
folder and a computer that does not answer told in plain words, its folders listed, a backup
copying it here and releasing it after, a failed run recorded, and its removal refused while a
backup uses it; five places of the alerts written in one script for root only, every place
reached by a report of the daemon, and one place failing not stopping the others; and the
maintenance started when enough files changed, and not when few did (`LAB_TEST_SLOW=0` skips
this part).

## What is emulated

- Every disk is a sparse image file, attached as a loop device with a partition table,
  formatted and mounted on `/mnt/lab/<disk>`. To SnapRAID these are separate physical disks.
- The disks, by the first letter of their name:

  | Disks | What | Setting |
  |---|---|---|
  | `d1`..`dN` | data disks of the array `default` | `LAB_DATA_DISKS` |
  | `p1`..`pN` | its parity disks, one for every level (1 to 6) | `LAB_PARITY_DISKS` |
  | `s1`..`sN` | blank spares | `LAB_SPARE_DISKS` |
  | `m1`..`mN`, `q1` | data and parity of the array `media`; `0`: no such array | `LAB_MEDIA_DATA_DISKS` |
  | `q2` | second half of the parity of `media` | `LAB_MEDIA_SPLIT_PARITY: "1"` |
  | `f1`..`fN`, `g1` | data and parity of the array `flash`; `0`: no such array | `LAB_FLASH_DATA_DISKS` |
  | `x1`..`xN` | mounted, in no array, pooled in `/mnt/scratch` | `LAB_SCRATCH_DISKS` |
  | `u1`..`uN` | mounted on their own: no array, no pool | `LAB_USB_DISKS` |

- Size: `LAB_DISK_SIZE_MB` for all, and `LAB_DISK_SIZES` for single disks, for example
  `"d1=256 d3=1024 p1=1024"`.
- Filesystem: ext4, or what `LAB_DISK_FS` says, for example `"d2=xfs f1=btrfs"`. XFS needs 300 MB
  and Btrfs 128 MB: a smaller disk gets ext4.
- Kind: `LAB_DISK_TYPES`, for example `"d1=hdd d2=smr d3=sas d4=ssd f1=nvme u1=usb"`. The kind
  decides two things. `smartctl` is replaced by a fake that answers from `/lab/smart/<disk>.env`
  in the format the real one uses for that kind of disk: ATA for SATA disks, SSDs and USB bridges,
  NVMe, or SCSI for SAS. SnapRAID reads the three of them, and takes from there interface,
  rotation, temperature, wear and the error counters. And `lsblk` is wrapped, so that the
  inventory of the Storage page gets model, serial, bus, rotation and "removable" of the disk the
  loop device stands for.
- Every array has its SnapRAID configuration (`/lab/etc/snapraid.conf`, `/lab/etc/snapraid/media.conf`,
  `/lab/etc/snapraid/flash.conf`) and its daemon options (`/lab/etc/snapraidd.conf`,
  `/lab/etc/snapraidd.d/media.conf`, `/lab/etc/snapraidd.d/flash.conf`).
- `LAB_POOLS: "1"` makes a mergerfs pool over the data disks of every array, and `/mnt/scratch`.
- `LAB_SHOWCASE: "1"` adds the less common options to the configurations (the table above), mounts
  the disks from `/etc/fstab` by UUID, and gives every pool its own placement policy. Without it
  the configurations are the plain ones the other tests work on.
- On first start the data disks get sample files, every array is synced once, and a few files are
  then added, changed, moved and deleted so the Differences page has content.

Three things are not like on a real machine. The kernel calls every loop device a rotating disk
and this cannot be changed, so SnapRAID spins down the emulated SSDs too (the array `flash` has
spin down off). The model of an NVMe or SAS disk comes from the kernel on a real machine; here
the fake `smartctl` adds it to its answer. And SnapRAID 15.1 names "SCSI" every disk that
answers in the SCSI format, so the SAS disk is shown as SCSI in the Disks page.

The container must be `privileged` (loop devices and mounts). If loop devices cannot be used it
falls back to tmpfs disks: the UI still works, but without SMART data and without persistence.
Run it only on a machine you use for development.

## Working on the UI

`quiet/`, `commander/` and `brutale/` of the daemon checkout are mounted into the container and
the daemon runs with `-N` (no cache): edit the HTML/CSS/JS and reload the browser. The lab opens
Quiet, the default of new installations; switch with `LAB_UI: "commander"` or `LAB_UI: "brutale"`
in `docker-compose.yml`. Where the folders are not mounted, the packed theme of the image is used.

The showcase lab starts with 60 days of made-up space samples (`snapraidd-space.log`), so the
forecast of Home ("full in about…") shows from the first minute. A real machine takes one sample a
day and shows a forecast after a week.

Changes to the C sources of the daemon need `docker compose up --build`.

REST API: `http://localhost:7627/snapraid/v1/{state,array,disks,tasks,activity,system,storage}`,
`/snapraid/v2/config`, Prometheus at `/metrics`. Full spec in `snapraidd.yaml` of the daemon.

## Making things happen

    docker exec snapraid-lab lab status
    docker exec snapraid-lab lab disks                 # every disk: array, role, kind, model, size, filesystem
    docker exec snapraid-lab lab sync media            # ask the daemon for a sync of an array, and wait
    docker exec snapraid-lab lab churn                 # new, changed, moved, deleted files
    docker exec snapraid-lab lab corrupt d2            # silent corruption, found by a scrub
    docker exec snapraid-lab lab delete d1 60          # mass deletion: trips the sync safety threshold
    docker exec snapraid-lab lab wipe d3               # an empty "replaced" disk to recover from the UI
    docker exec snapraid-lab lab smart d1 REALLOCATED=120 TEMP=58
    docker exec snapraid-lab lab smart p1 FAILING=1
    docker exec snapraid-lab lab smart f1 WEAR_USED=97 SPARE=9   # NVMe: wear and spare blocks
    docker exec snapraid-lab lab inbox                 # what the daemon notified; lab inbox 3 shows the third
    docker exec snapraid-lab lab hooks                 # the calls of the hook script
    docker exec snapraid-lab lab hooks block           # the hook refuses the next tasks; lab hooks allow

SMART changes show up at the next probe (every minute).

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | builds the engine and the daemon, installs the fake smartctl; with `LAB_PACKAGES=1` also the package of the daemon and the engines of the installation test |
| `docker-compose.yml` | the showcase lab: disks, sizes, kinds, filesystems, UI choice, port, volumes |
| `docker-compose.simple.yml` | a small lab: one array of equal disks |
| `docker-compose.showcase.yml` | the showcase lab, running `tests/showcase-test.sh` |
| `docker-compose.test.yml` | throwaway lab that runs `tests/api-test.sh` |
| `docker-compose.sizes.yml` | throwaway lab of mixed disk sizes that runs `tests/mixed-size-test.sh` |
| `docker-compose.arrays.yml` | throwaway lab that runs `tests/multi-array-test.sh` |
| `docker-compose.machine.yml` | the showcase lab, running `tests/machine-test.sh` |
| `docker-compose.tiers.yml` | the showcase lab, running `tests/tiers-test.sh` |
| `docker-compose.extras.yml` | the showcase lab, running `tests/extras-test.sh` |
| `docker-compose.existing.yml` | no lab: a machine already using SnapRAID from the shell, for `tests/existing-setup-test.sh` |
| `entrypoint.sh` | creates and mounts the disks, writes the configs, starts `snapraidd` |
| `fake-smartctl`, `smartctl-launcher.c` | SMART emulation, self-tests included (SnapRAID only runs real binaries, hence the launcher) |
| `fake-lsblk` | `lsblk` with the model, serial and bus of the emulated disks |
| `hook.sh`, `notify.sh` | what the hook and the notifications of the daemon run in the showcase lab |
| `lab` | the helper used above |
| `docs/screenshots/` | the pictures of this page |
| `docs/tools/` | the script and the lists that take them |

Array and daemon configs live in the `lab` volume, under `/lab/etc`.

## Licence

GPL-3.0-or-later, the same licence as SnapRAID and SnapRAID Daemon. See `LICENSE`.
