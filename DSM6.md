# DSM 6 compatibility notes

The main scripts formally support DSM 6 (`DSM_SUPPORTED_VERSION=6` in
`syno_docker_update.sh`), but the DSM 6 code paths appear to have gone
untested for a while - several commands and assumptions baked into the
scripts turned out to be DSM 7-only. This file tracks what's been found
and fixed on a real DSM 6.2.4 box, so fixes don't get rediscovered or
lost if this stays a fork instead of landing upstream.

Branch: `dsm6-compatibility` (merges the individual fix branches below).

## Confirmed DSM 6 environment

- DSM 6.2.4, kernel `3.10.105`
- No systemd at all - services run through `synoservicectl` (sysvinit-style
  `start-stop-status` scripts) or Upstart (`initctl`), not units/drop-ins
- `synoinfo.conf` has no `platform_name` key (DSM 7 only); the platform
  codename has to be read from `unique` instead
- `ar` is not in the base userland (available via the SynoCli Development
  Tools package from SynoCommunity, but shouldn't be a hard requirement)

## Fixes so far

1. **`synoservicectl` service id mismatch** (branch `fix/synoservicectl-pkgctl-prefix`)
   - `synoservicectl --status Docker` always failed with
     `error unknow [0x4000 servicectl_status.c:27]`, even though
     `synoservicectl --status pkgctl-Docker` worked - the real service id
     has a `pkgctl-` prefix the script never used.
   - This made `get_syno_status` return `unknown` forever, so
     `wait_for_syno_stopped` always hit its timeout regardless of whether
     Docker had actually stopped - looked like a hung container, wasn't.
   - Fix: `resolve_syno_servicectl_id()` probes the bare name and the
     `pkgctl-` prefixed name once, caches whichever responds with a real
     status, and falls back to the bare name if neither does (so other
     DSM 6 units that *don't* need the prefix aren't broken by hardcoding it).

2. **Blank platform name breaks the iptables module download URL**
   (branch `fix/dsm6-platform-name-detection`)
   - `install_iptables_modules.sh` read `platform_name` from
     `synoinfo.conf`, which doesn't exist on DSM 6, so `PLATFORM_VERSION`
     came back empty and every module download URL was built with the
     platform segment missing - looked like "no modules for your platform"
     when the real bug was never knowing the platform at all.
   - Fix: fall back to parsing the platform codename out of `unique`
     (`synology_<platform>_<model>`), and hard-fail with a clear message
     if neither key is found.

3. **`ar: command not found`** (branch `fix/fuse3-deb-extract-without-ar`)
   - `install_fuse_overlayfs.sh` used `ar x` to unpack the fuse3/libfuse3
     `.deb` packages. DSM's base userland has no `ar` binary.
   - Fix: `extract_deb_data_tar()` still uses real `ar` when present, but
     falls back to a pure `tail`/`head`/`cut` parser of the `.deb`'s ar
     archive layout (fixed 60-byte headers, no GNU long-name table, since
     every member name in a .deb is short) when it isn't. Verified
     byte-for-byte against real `ar` output on the pinned fuse3 and
     libfuse3-3 `.deb`s.
   - Confirmed independently: installing SynoCommunity's "SynCli
     Development Tools" package puts a real `ar` on the box, which this
     fallback correctly defers to.

4. **`systemctl: command not found` in the fuse-overlayfs iptables workaround**
   (same branch as #3)
   - `configure_iptables_raw()` in `install_fuse_overlayfs.sh` only knew
     how to relax Docker's `iptable_raw` requirement via a systemd
     drop-in - which doesn't exist on DSM 6.
   - Fix: on DSM 6 (detected by the absence of `/run/systemd/system` +
     `systemctl`), export `DOCKER_INSECURE_NO_IPTABLES_RAW=1` directly
     from `start-stop-status` instead, anchored on the same
     `iptablestool --insmod ...` line `install_iptables_modules.sh`
     already inserts after. `uninstall()` and the final activation hints
     (`synopkg` vs `synoservicectl`) follow the same branch.

5. **`cp: ... Text file busy` on `containerd`, then Docker fails to start**
   (not actually DSM 6-specific - would hit DSM 7 `--fuse-overlayfs` users
   too, just found here)
   - `setup_fuse_overlayfs()` started the separate containerd (used by the
     fuse-overlayfs snapshotter) immediately after configuring it, which is
     *before* Docker gets stopped and its binaries replaced. That process
     keeps `.../target/usr/bin/containerd` open for the rest of the run, so
     `execute_install_bin`'s `cp .../docker/* .../bin/` can't overwrite that
     one file ("Text file busy") - but since the script has no `set -e` and
     `cp src/* dst/` is one invocation, every *other* file still got copied.
     Result: dockerd silently ended up on the new version while containerd
     stayed on the old one, which then failed to start with a useless
     `error unknow`.
   - Fix: moved starting the fuse-overlayfs rc.d script from
     `setup_fuse_overlayfs()` (before the stop/replace) to
     `execute_start_syno()` (after binaries are installed, right before
     starting Docker) - the one firm guarantee is CM/Docker is fully stopped
     at that point, so nothing is still holding the old binary. Also made
     `execute_install_bin`'s `cp` fail loudly (`terminate`) instead of
     silently continuing, so a mixed-version binary set can't happen unnoticed
     again regardless of cause.
   - If you hit the mixed-version state before this fix: just re-run the same
     `update` command. It re-extracts and re-copies every binary from the
     downloaded tarball, so it self-heals once the ordering bug no longer
     leaves containerd busy during the copy.
   - Turned out insufficient on its own (see #6) - the real fix needed a
     symmetric stop, not just a later start.

6. **Still `Text file busy` on `containerd`, even after #5** (same branch)
   - `FUSE_OVERLAYFS_RC_SCRIPT start` is only ever called once, in
     `execute_start_syno()` - nothing in the main script ever stops it
     again. Its external containerd process is meant to keep running for
     as long as Docker uses fuse-overlayfs, so it survives fine across a
     normal reboot or a `syno start`/`syno stop` of just the Docker
     package. But it also survives across *re-running this script*, so a
     previous run's still-running instance held the binary open through a
     later run's `execute_install_bin`, even with the start moved later in
     fix #5 - there was nothing left in *this* run holding it busy, but the
     orphan from the *last* run was.
   - Fix: added a matching `FUSE_OVERLAYFS_RC_SCRIPT stop` to the end of
     `execute_stop_syno()`, once Docker/ContainerManager is confirmed fully
     stopped (dockerd depends on it while running, so it's stopped only
     after, not before). Now every run's own stop/start pair brackets the
     binary swap cleanly regardless of what an earlier run left behind.
   - Needed a one-time manual recovery on the box this was found on: a
     stuck orphan from before this fix existed had to be killed by hand
     (`sudo /usr/local/etc/rc.d/containerd-fuse-overlayfs.sh stop`, or
     `pkill` the `containerd --config /etc/containerd/config.toml`
     process directly) before the next run could succeed.

7. **`userland-proxy is enabled, but userland-proxy-path is not set`** (not
   DSM 6-specific - any DSM box upgrading to Docker 27+ would hit this,
   found here first)
   - Docker 27's dockerd stopped auto-discovering `docker-proxy` (via PATH
     or a hardcoded default) when `userland-proxy` is enabled (the
     default), and now refuses to start at all unless the config file says
     where it is. Synology installs `docker-proxy` outside dockerd's
     built-in search paths, so this always needs to be explicit on a
     Synology box; it just wasn't, since older Docker didn't require it.
   - This is most likely the *real* reason `pkgctl-Docker failed to
     Start.. error unknow` showed at Step 10 - `synoservicectl` swallows
     dockerd's actual stderr, but running dockerd by hand with the same
     config reproduced this exact validation error immediately.
   - Fix: `syno_docker_switch_logger.sh` (runs on every `logger`/`update`/
     `install`, already rewrites several dockerd.json keys) now also sets
     `userland-proxy-path`, derived from the dockerd.json path it's
     already given (`<pkg dir>/etc/dockerd.json` -> `<pkg dir>/target/usr/bin/docker-proxy`)
     rather than needing a new argument.

8. **`--uninstall` hit the same `systemctl: command not found` it was
   cleaning up after**
   - The very first (pre-fix) `--fuse-overlayfs` attempt on this box got
     as far as `mkdir`+`printf`-ing the systemd drop-in file before
     crashing on the `systemctl daemon-reload` right after it (fix #4,
     above) - leaving that drop-in file sitting on disk despite there
     being no systemd on this host at all.
   - `remove_iptables_raw_workaround()`'s cleanup checked "does the
     drop-in file exist" to decide whether to run `systemctl
     daemon-reload`, not "is this actually a systemd host" - so cleaning
     up that one stale leftover file hit the identical crash.
   - Fix: guard that call on `USE_SYSTEMD` instead of file presence.

## Early warning added

- **`check_glibc_for_fuse3()`**, run first thing in
  `install_fuse_overlayfs.sh` (before any download, before touching
  `dockerd.json` or the Synology updater): compares the host's glibc
  (parsed from `ldd --version`) against `2.34` - the highest floor among
  everything the pinned `fuse3`/`libfuse3-3` `.deb`s need - and `terminate`s
  with an explanation + the "stay on aufs, target below 24" advice
  immediately if it's too old, instead of letting someone else rediscover
  the dead end below the hard way, multiple layers of config changes deep.
  Re-check this threshold if `FUSE3_DEB_VERSION` is ever bumped - a newer
  pin may need a newer glibc floor.

## Dead end found - not pursuing

- **fuse-overlayfs doesn't work on this box at all**, independent of
  everything above. `containerd-fuse-overlayfs-grpc`'s own startup
  healthcheck mount failed:
  `mount.fuse3: /lib/libc.so.6: version 'GLIBC_2.28' not found`.
  Checked Debian's archive: the *oldest* fuse3 package still published
  anywhere (buster, `3.4.1-1+deb10u1`) already requires glibc >= 2.28.
  DSM 6.2.4's glibc predates that, so no Debian-packaged fuse3 build - not
  even a much older one - will ever satisfy this host via the approach
  `install_fuse_overlayfs.sh` uses (containerd snapshotter proxy_plugin,
  which needs `mount.fuse3`/`libfuse3.so.3`).
  - Practical ceiling on this specific hardware: stay on `aufs` (works
    today) and keep the Docker target below 24 - `aufs` was dropped in
    Docker 24+ with nothing but `overlay2` (unavailable - old kernel, no
    overlay module) or `fuse-overlayfs` (unavailable - see above) as
    replacements.
  - A real fix would mean reworking `install_fuse_overlayfs.sh` to use
    Docker's classic fuse-overlayfs graphdriver instead of a containerd
    snapshotter proxy_plugin - the graphdriver execs the statically-linked
    `fuse-overlayfs` binary directly and may not need `mount.fuse3`/
    `libfuse3.so.3` at all. Not attempted yet; substantial rework, not a
    quick patch.

## Known but not yet fixed

- No precompiled `iptable_raw.ko`/`ip6table_raw.ko` exist for kernel
  `3.10.105` in `telnetdoogie-labs/synology-kernelmodules` (only
  `3.10.108`, `4.4.302+`, `5.10.55+` are catalogued) - this only matters
  for Docker 28+, which needs those modules; staying on a 27.x target
  avoids the requirement entirely.
  - Compiling a matching `3.10.105` module is possible in principle (the
    repo's `Dockerfile_legacy` flow + a hand-built `platforms.json`
    pointing at DSM 6.2.4's own GPL kernel source instead of DSM 7's),
    but needs the exact platform name (one of `avoton`/`braswell`/
    `bromolow`/`grantley`/`cedarview`) confirmed first, and hasn't been
    attempted yet.

## Working path on this hardware (summary)

- `./syno_docker_update.sh logger` - works after fix #1
- `--fuse-overlayfs` is a dead end on this box (glibc too old - see
  above) - `check_glibc_for_fuse3()` now refuses it outright before
  touching anything.
- **Confirmed working**: `./syno_docker_update.sh update -d 23.0.6 --force`
  (`aufs`, no `--fuse-overlayfs`) - clean run start to finish, Docker
  started on the first try after fixes #1-#8. `23.0.6` is the practical
  ceiling on this hardware: the last Docker major that still supports
  `aufs`, since neither `overlay2` nor `fuse-overlayfs` are available here.
  - `--force` was needed because Docker was already stopped/broken from
    the earlier `--fuse-overlayfs` attempts; not needed on a clean start.
