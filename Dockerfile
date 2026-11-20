# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# SnapRAID + SnapRAID Daemon lab image.
#
# The SnapRAID engine is the original one, taken from its repository at a pinned release.
# The daemon comes from the "daemon" build context: a checkout of
# https://github.com/paleka/snapraid-daemon (branch storage), see docker-compose.yml.
FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential autoconf automake git zlib1g-dev zip ca-certificates nodejs && rm -rf /var/lib/apt/lists/*

# SnapRAID engine, by Andrea Mazzoleni. The commit is checked, because a tag can be moved.
ARG SNAPRAID_REPO=https://github.com/amadvance/snapraid.git
ARG SNAPRAID_TAG=v15.1
ARG SNAPRAID_COMMIT=4054832c7e385388c6629561bf0ddb16b95698b5
RUN git clone --depth 1 --branch "$SNAPRAID_TAG" "$SNAPRAID_REPO" /src/snapraid \
 && test "$(git -C /src/snapraid rev-parse HEAD)" = "$SNAPRAID_COMMIT" \
 && cd /src/snapraid && ./autogen.sh \
 && mkdir /build-engine && cd /build-engine \
 && /src/snapraid/configure --prefix=/usr --sysconfdir=/etc && make -j"$(nproc)"

COPY smartctl-launcher.c /src/
RUN gcc -O2 -o /smartctl /src/smartctl-launcher.c

# SnapRAID Daemon with the Storage page. Whatever was built in the checkout is dropped
# (only ignored files are removed), then it is built out of tree.
COPY --from=daemon . /src/snapraid-daemon
RUN cd /src/snapraid-daemon \
 && git config --global --add safe.directory /src/snapraid-daemon \
 && if [ -e .git ]; then git clean -Xfdq || true; fi \
 && ./autogen.sh \
 && mkdir /build-daemon && cd /build-daemon \
 && /src/snapraid-daemon/configure --prefix=/usr --sysconfdir=/etc && make -j"$(nproc)"
# Unit tests: the daemon selftest (validation, fstab editing, pool helpers) and the logic of the
# Storage page. A failure stops the build.
RUN cd /build-daemon && make check

# The package of the daemon and its installer, for the test of an installation on a machine
# already using SnapRAID (docker-compose.existing.yml). Built only when asked: the packages
# are for x86-64 only. The version comes from the tags of the checkout.
ARG LAB_PACKAGES=0
RUN mkdir /pkg && if [ "$LAB_PACKAGES" = 1 ]; then \
        cd /src/snapraid-daemon && ./configure > /dev/null && make dist > /dev/null \
     && bash makedeb.sh > /dev/null \
     && cp snapraid-daemon-storage_*_amd64.deb /pkg/daemon.deb && cp installer.sh /pkg/installer.sh; \
    fi

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        zlib1g e2fsprogs xfsprogs btrfs-progs fdisk util-linux mergerfs fuse3 rsync attr jq procps curl ca-certificates \
        samba-common-bin samba hdparm ethtool psmisc && rm -rf /var/lib/apt/lists/*
COPY --from=build /build-engine/snapraid /usr/bin/snapraid
COPY --from=build /build-daemon/snapraidd /usr/sbin/snapraidd
COPY --from=build /build-daemon/quiet.zip /build-daemon/commander.zip /build-daemon/brutale.zip /usr/share/snapraidd/
COPY --from=build /smartctl /usr/sbin/smartctl
COPY fake-smartctl /usr/libexec/lab/fake-smartctl
# In front of the real lsblk (/usr/bin) in the search path of the daemon: it gives the emulated disks a model and a bus.
COPY fake-lsblk /usr/sbin/lsblk
COPY hook.sh notify.sh /usr/local/share/lab/
COPY entrypoint.sh /usr/local/bin/lab-entrypoint
COPY lab /usr/local/bin/lab
COPY tests /usr/local/share/lab/tests
# The engines for the same test: the one of the distribution (SnapRAID 12, whose content file
# SnapRAID 15 refuses), SnapRAID 14.10 that converts it, and SnapRAID 15, from the releases of
# their author. The checksums are the ones of the CHECKSUMS file of SnapRAID.
ARG LAB_PACKAGES=0
COPY --from=build /pkg /usr/local/share/lab/pkg
RUN if [ "$LAB_PACKAGES" = 1 ]; then \
        cd /usr/local/share/lab/pkg \
     && apt-get update && apt-get download snapraid && mv snapraid_*.deb snapraid-old.deb \
     && rm -rf /var/lib/apt/lists/* \
     && curl -fsSL -o snapraid-migrate.deb https://github.com/amadvance/snapraid/releases/download/v14.10/snapraid_14.10-1_amd64.deb \
     && curl -fsSL -o snapraid-new.deb https://github.com/amadvance/snapraid/releases/download/v15.2/snapraid_15.2-1_amd64.deb \
     && echo "15f5fd9f639912c94daae9d75d3567b7a3fc0e18475880f972acd8d8e9e0992c  snapraid-migrate.deb" | sha256sum -c - \
     && echo "9c78f158347cc0340ed5c9877724bb4f3b5e5fb48b43332ee7e0e7b6a63642d9  snapraid-new.deb" | sha256sum -c -; \
    fi
RUN chmod 755 /usr/libexec/lab/fake-smartctl /usr/sbin/lsblk /usr/local/share/lab/hook.sh /usr/local/share/lab/notify.sh /usr/local/bin/lab-entrypoint /usr/local/bin/lab /usr/local/share/lab/tests/*.sh
EXPOSE 7627
ENTRYPOINT ["/usr/local/bin/lab-entrypoint"]
