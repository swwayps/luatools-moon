# Bundled CloudRedirect hook

Patched 32-bit build of [CloudRedirect](https://github.com/Selectively11/CloudRedirect),
giving unowned (lua) games Steam Cloud sync to the user's own Drive / OneDrive /
local folder. The installer deploys it; the Steam wrapper injects it via
`LD_PRELOAD`.

Tracks upstream (pinned at `0251ed9`, 2.1.8) plus fixes not yet shipped there:

- **Attach wait 10s → 120s** — else the hook never attaches on slow-boot
  distros (Arch/CachyOS).
- **CAS SHA-leaf strip in the legacy path** — else old 2.0.x saves restore to a
  broken `<file>/<sha>` directory.
- **Worker-thread exception containment** — else one bad blob aborts the client.
- **GOT-decoded engine pointer + guarded KV reads** — else a `steamclient.so`
  layout shift (Steam `1781041600`) segfaults the client at launch. Quota
  metadata only; save data is untouched.

## Rebuild

```sh
./build.sh   # needs podman/docker; clones upstream, applies the patch, verifies
```

Output stays 32-bit and links no glibc newer than the Steam runtime ships
(asserted by `build.sh`).

## Companion app

The `.so` only redirects cloud RPCs. Provider login (Drive / OneDrive OAuth) is
the upstream flatpak app (`org.cloudredirect.CloudRedirect`), fetched by the
installer when flatpak is present.
