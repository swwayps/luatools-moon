# License notice

`slsteammoon-ltsteamplugin` is a Linux port and integration layer for
the LuaTools Millennium plugin, targeting the [slsteam-moon](https://github.com/nwrafael/slsteam-moon)
project. This notice records provenance so contributors can keep the
boundaries clear.

## Upstream: LuaTools (ltsteamplugin)

Vendored pristine at `upstream/luatools/`. Source: `ltsteamplugin.zip`
from [piqseu/ltsteamplugin](https://github.com/piqseu/ltsteamplugin)
GitHub releases (the official release line). Original plugin authored
by [madoiscool](https://github.com/madoiscool/ltsteamplugin); earlier
forks include [skyflarefox](https://github.com/skyflarefox/plugin).

The upstream zip ships without a `LICENSE` file. The fork keeps the
vendored tree byte-for-byte and applies changes only at build time, so
the shipped backend inherits the upstream license terms (such as they
are). If/when upstream clarifies licensing, this section should be
updated.

## Adaptation overlay (this repo's contribution)

Original work for this fork:

- `linux/` — the Linux overlay files:
  - `backend/slsteam.lua` — registers added appids into SLSsteam's
    `AdditionalApps:` (`~/.config/SLSsteam/config.yaml`).
  - `backend/scripts/restart_steam.sh` — wrapper-aware Steam restart.
  - `backend/api.json` — default API list with SkyAPI added.
- `scripts/` — `build.sh` (assembles `dist/luatools` from upstream +
  overlay via anchored patches), `patch-frontend.sh`, and
  `rebase-upstream.sh`.
- `install.sh`, `README.md`, this notice.

The fork does NOT edit the vendored upstream in place. `build.sh`
applies small, anchored patches to a copy, so a future upstream rebase
is `rebase-upstream.sh <new.zip>` followed by fixing any anchor that
moved (the build fails loudly if one does).

Contributor: nwrafael <newrafael@proton.me>.

License: same as `slsteam-moon` (AGPL-3.0) until the upstream LuaTools
licensing is clarified, at which point this overlay can be re-licensed
to match if the original author's terms allow it.

## Related projects (not vendored, referenced only)

- [Millennium](https://github.com/SteamClientHomebrew/Millennium) —
  MIT-licensed Steam client modding framework. Required runtime; not
  redistributed by this repo.
- [SLSsteam](https://github.com/AceSLS/SLSsteam) — AGPL-3.0. The
  upstream of slsteam-moon. Not redistributed.
- [LuaToolsLinux 1.x](https://github.com/Star123451/LuaToolsLinux) —
  prior Linux port by StarWarsK & geovanygrdt. Referenced for path
  resolution patterns; no code copied directly.
- [CloudRedirect](https://github.com/Selectively11/CloudRedirect) by
  Selectively11 — optional cloud-save redirection. **Not redistributed**: the
  installer downloads `cloud_redirect.so` from the project's GitHub releases at
  install time and, when flatpak is available, installs the project's flatpak
  companion app from its release bundle. No CloudRedirect code or binaries are
  vendored in this repo. License terms are the upstream project's.
