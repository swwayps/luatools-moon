# Bundled CloudRedirect hook

This folder ships a patched build of
[CloudRedirect](https://github.com/Selectively11/CloudRedirect)'s 32-bit Linux
hook (`cloud_redirect.so`). The installer (`../install.sh`) deploys this exact
binary to `~/.local/share/CloudRedirect/cloud_redirect.so` instead of
downloading from upstream releases, because we need two fixes that no upstream
release ships together.

## Why a custom build

CloudRedirect gives unowned (lua) games real Steam Cloud sync, redirected to
the user's own Google Drive / OneDrive / local folder. Two upstream versions
each had a blocking problem on our stack:

- **2.0.4** (`linux` release tag, an LD_AUDIT library): attaches reliably, but
  it lacks the CAS path normalization. It restores each save to a directory
  named after the file with the content SHA as the leaf
  (`AUTOSAVE.es3/<sha40>`) instead of the real file, so games show "no save"
  and new saves don't sync. It also corrupts the client heap when driven hard.

- **2.1.5** (`latest`, an LD_PRELOAD library): has `StripCasShaLeaf()` which
  restores saves to the real filename (the actual fix), but its
  `DeferredInit` polls for `steamclient.so` for a hard-coded 10 seconds, then
  gives up permanently. On slower-bootstrapping distros (Arch/CachyOS)
  steamclient.so maps after that window, so the hook never attaches.

This build takes 2.1.5 (correct save restore) and:

1. Extends the steamclient.so wait from 10s to 120s so the LD_PRELOAD load
   path attaches on slow-bootstrap distros too (no LD_AUDIT — loading 2.1.5 as
   an auditor corrupts the client heap with `realloc(): invalid pointer`).
2. Strips the CAS SHA leaf in the legacy-manifest migration path as well, so
   saves already stored on the cloud by an older (2.0.x) build are healed on
   first sync instead of restoring to the broken `<file>/<sha>` layout.

The Steam wrapper (slsteam-moon `setup.sh`) injects this `.so` via
**LD_PRELOAD**, after which the library self-removes from `LD_PRELOAD` so child
processes (the game, steamwebhelper) don't inherit it.

## Files

- `cloud_redirect.so` — the prebuilt 32-bit hook the installer deploys.
- `slsteammoon-cloudredirect.patch` — our changes on top of upstream.
- `Dockerfile.builder` — glibc-2.35 (Ubuntu 22.04) + gcc-12 build environment.
- `build.sh` — clones upstream at the pinned commit, applies the patch, builds
  in the container, and verifies the result.

## Rebuilding

```sh
./build.sh
```

Requires podman or docker. Pinned upstream base commit:
`4dd8a655567bcde62a17c3a3505deb6f20530847` (ReleaseVersion 2.1.5).

The build must stay 32-bit and must not require glibc newer than the Steam
runtime ships (no `GLIBC_ABI_GNU_TLS`, nothing `>= GLIBC_2.36`); `build.sh`
asserts both.

## Companion app

The `.so` only redirects the cloud RPCs. The provider login (Google Drive /
OneDrive OAuth) is done by the upstream flatpak companion app
(`org.cloudredirect.CloudRedirect`), which the installer still fetches from
upstream releases when flatpak is available.
