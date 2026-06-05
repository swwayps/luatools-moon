# 🌕 slsteammoon-ltsteamplugin

Set up slsteam-moon, Millennium and the LuaTools plugin automatically with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/nwrafael/slsteammoon-ltsteamplugin/main/install.sh | bash
```

> **Requirements:** Linux x86_64 and **native Steam** installed from your package
> manager. Flatpak and Snap Steam are not supported — Millennium does not work with them.

---

Linux port of the `ltsteamplugin` Millennium plugin, built exclusively for the [slsteam-moon](https://github.com/nwrafael/slsteam-moon) project. It serves as an integration layer that fetches manifest packs and installs them for slsteam-moon to consume natively on Linux.

## Credits

Upstream:

- [piqseu](https://github.com/piqseu/ltsteamplugin) — the `ltsteamplugin`
  release line this fork tracks. Originally by
  [madoiscool](https://github.com/madoiscool/ltsteamplugin), with earlier
  forks by [skyflarefox](https://github.com/skyflarefox/plugin).

Reference material:

- [StarWarsK & geovanygrdt](https://github.com/Star123451/LuaToolsLinux) —
  prior Linux port.
- [Millennium](https://github.com/SteamClientHomebrew/Millennium) —
  Steam client modding framework.

## Support

Reach out by email: newrafael@proton.me

## Uninstall

Want to remove everything? Run:

```bash
curl -fsSL https://raw.githubusercontent.com/nwrafael/slsteammoon-ltsteamplugin/main/uninstall.sh | bash
```
