# 🌕 slsteammoon-ltsteamplugin

Set up slsteam-moon, Lumen and the LuaTools plugin automatically with a single command:

```bash
curl -fsSL https://codeberg.org/unplausible/slsteammoon-ltsteamplugin/raw/branch/main/install.sh | bash
```

> **Requirements:** Linux x86_64 and **native Steam** installed from your package
> manager. Flatpak and Snap Steam are not supported.
>
> **Want Steam theme support?** Use the [`millennium` branch](https://codeberg.org/unplausible/slsteammoon-ltsteamplugin/src/branch/millennium).

---

Linux port of the `ltsteamplugin` plugin, built exclusively for the [slsteam-moon](https://codeberg.org/unplausible/slsteam-moon) project. It serves as an integration layer that fetches manifest packs and installs them for slsteam-moon to consume natively on Linux.

## Credits

Upstream:

- [piqseu](https://github.com/piqseu/ltsteamplugin) — the `ltsteamplugin`
  release line this fork tracks. Originally by
  [madoiscool](https://github.com/madoiscool/ltsteamplugin).

Reference material:

- [StarWarsK & geovanygrdt](https://github.com/Star123451/LuaToolsLinux) —
  prior Linux port.
- [Millennium](https://github.com/SteamClientHomebrew/Millennium) —
  Steam client modding framework.
- [CloudRedirect](https://github.com/Selectively11/CloudRedirect) by
  Selectively11 — optional cloud saves for unowned games.

## Support

Open an issue: https://codeberg.org/unplausible/slsteammoon-ltsteamplugin/issues

## Uninstall

Want to remove everything? Run:

```bash
curl -fsSL https://codeberg.org/unplausible/slsteammoon-ltsteamplugin/raw/branch/main/uninstall.sh | bash
```
