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

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        zlib1g e2fsprogs xfsprogs fdisk util-linux mergerfs fuse3 rsync attr jq procps curl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /build-engine/snapraid /usr/bin/snapraid
COPY --from=build /build-daemon/snapraidd /usr/sbin/snapraidd
COPY --from=build /build-daemon/commander.zip /build-daemon/brutale.zip /usr/share/snapraidd/
COPY --from=build /smartctl /usr/sbin/smartctl
COPY fake-smartctl /usr/libexec/lab/fake-smartctl
COPY entrypoint.sh /usr/local/bin/lab-entrypoint
COPY lab /usr/local/bin/lab
COPY tests /usr/local/share/lab/tests
RUN chmod +x /usr/libexec/lab/fake-smartctl /usr/local/bin/lab-entrypoint /usr/local/bin/lab /usr/local/share/lab/tests/*.sh
EXPOSE 7627
ENTRYPOINT ["/usr/local/bin/lab-entrypoint"]
