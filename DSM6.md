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
- `./syno_docker_update.sh update --fuse-overlayfs -d 27.5.1` - avoids the
  28+ iptables-module requirement entirely while still fixing the
  `aufs` + Docker 24+ incompatibility via fuse-overlayfs
