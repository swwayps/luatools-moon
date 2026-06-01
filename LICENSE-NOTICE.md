# License notice

`slsteammoon-luatools` is a Linux port and integration layer for two
upstream projects. Each carries its own license; this notice records
the provenance so contributors can keep the boundaries clear.

## Upstream: LuaTools (Windows)

Vendored at `upstream/luatools/`. Source: `luatools.zip` 2.7.5,
distributed by [skyflarefox/plugin](https://github.com/skyflarefox/plugin)
GitHub releases (downloaded as `luatools.zip`). Original plugin
authored by [madoiscool](https://github.com/madoiscool/ltsteamplugin).

The upstream zip ships without a `LICENSE` file. The original
`ltsteamplugin` repository is also unlicensed at the time of writing.
`shared/backend/main.lua` is a near-verbatim copy of upstream's
`backend/main.lua` with localized adaptation patches; it inherits the
upstream license terms (such as they are).

If/when upstream clarifies licensing, this section should be updated
and `shared/backend/main.lua` should be re-checked against the
declared terms.

## Adaptation overlay (this repo's contribution)

Files under `linux/`, `scripts/`, this `README.md`, and the
`-- ADAPT-LINUX:` patch fragments inside `shared/backend/main.lua`
are original work for this fork.

Contributor: nwrafael <newrafael@proton.me>.

License: same as `slsteam-moon` (AGPL-3.0) until the upstream
LuaTools licensing is clarified, at which point this overlay can be
re-licensed to match if the original author's terms allow it.

## Related projects (not vendored, referenced only)

- [Millennium](https://github.com/SteamClientHomebrew/Millennium) —
  MIT-licensed Steam client modding framework. Required runtime; not
  redistributed by this repo.
- [SLSsteam](https://github.com/AceSLS/SLSsteam) — AGPL-3.0. The
  upstream of slsteam-moon. Not redistributed.
- [LuaToolsLinux 1.x](https://github.com/Star123451/LuaToolsLinux) —
  prior Linux port by StarWarsK & geovanygrdt. Referenced for path
  resolution patterns; no code copied directly.
