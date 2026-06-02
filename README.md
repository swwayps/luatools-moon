# slsteammoon-ltsteamplugin

Linux port of [LuaTools](https://github.com/skyflarefox/plugin)
(`luatools.zip` 2.7.5 by Skyflare / madoiscool), the Millennium-based
Steam plugin that fetches Lua manifest packs and drops them into
`config/stplug-in/` for [SLSsteam](https://github.com/AceSLS/SLSsteam)
/ [slsteam-moon](https://github.com/nwrafael/slsteam-moon) to consume.

This fork talks exclusively to the slsteam-moon `.so` — the
Accela / DepotDownloaderMod path from the original LuaToolsLinux is
gone. Front-end UX is identical to the Windows LuaTools 2.7.5: click
"Add via LuaTools" on a store page → game appears in the library →
install through Steam itself.

Compatible with **Millennium v3.1.0+** (Lua-only backend).

## Repository layout

```
slsteammoon-ltsteamplugin/
├── upstream/luatools/         pristine vendor of luatools.zip 2.7.5
│   ├── plugin.json            (kept verbatim)
│   ├── backend/               (main.lua, .ps1 workers, locales, ...)
│   └── public/                (frontend bundle)
├── shared/backend/main.lua    upstream main.lua + ADAPT-LINUX patches
├── linux/backend/             Linux-only adaptation overlay
│   ├── platform.lua           (concrete platform.* implementation)
│   └── platform/workers/      (bash workers replacing the .ps1 set)
├── scripts/
│   ├── build.sh               assemble dist/luatools/ from the three roots
│   └── rebase-upstream.sh     pull a new upstream zip + 3-way merge
└── dist/                      build output (gitignored)
```

`upstream/` and `linux/` never share files. `shared/backend/main.lua`
is the only place where the cross-platform code lives, and every
divergence from upstream is marked with an `-- ADAPT-LINUX:` comment
so the rebase tool can find them.

## How the platform split works

The Windows LuaTools backend mixes platform-specific calls
(`Kernel32`, `Shell32`, `Advapi32`, `powershell.exe`, `cmd.exe`,
`wscript.exe`) directly into `main.lua`. We can't strip those out
without losing diff-ability against upstream, and we can't keep
them as-is on Linux. The compromise:

1. Every Windows-specific line in `shared/backend/main.lua` is
   replaced by a call into a `platform` module, with the original
   intent annotated by an `-- ADAPT-LINUX:` comment.
2. `linux/backend/platform.lua` is the Linux implementation of that
   module. It uses LuaJIT FFI for things that need it (nanosleep)
   and shells out to standard userland tools (`mkdir -p`, `unzip`,
   `find`, `xdg-open`, `touch`) for everything else.
3. The four powershell/cmd workers (`download_worker.ps1`,
   `fix_worker.ps1`, `steam_scan_helper.ps1`,
   `restart_steam.cmd`) are mirrored by bash equivalents under
   `linux/backend/platform/workers/`. The worker contract — args,
   JSON state file shape, polling — is identical, so the frontend
   has no idea the platform changed.

If `platform.lua` fails to `require` (overlay missing or broken),
`shared/main.lua` falls back to a no-op shim. Path joins still work
in that mode, but workers and Steam control are inert. This is
intentional: the plugin loads and reports a clean error rather than
crashing Millennium.

### Touchpoints map

Every site marked `-- ADAPT-LINUX:` in `shared/backend/main.lua`
maps to a `platform.*` function:

| Site | Windows behaviour | Linux behaviour |
|---|---|---|
| `ensure_dir` | `Kernel32!CreateDirectoryA` loop / wscript fallback | `mkdir -p` |
| `list_files_recursive` | `powershell Get-ChildItem -Recurse` | `find -type f` |
| `poke_steam_config_watchers` | `powershell` LastWriteTime + probe | `touch` + ephemeral probe file (inotify-friendly) |
| `sleep_ms` | `Kernel32!Sleep` / busy-wait fallback | FFI `nanosleep` / `sleep` shell |
| `launch_download_worker` | hidden `powershell.exe download_worker.ps1` | `setsid bash download_worker.sh` |
| `run_scan_helper` | hidden `powershell.exe steam_scan_helper.ps1` | `bash steam_scan_helper.sh` (sync poll) |
| `launch_fix_worker` | hidden `powershell.exe fix_worker.ps1` | `setsid bash fix_worker.sh` (currently stubbed) |
| `cleanup_temp_download_artifacts` | `powershell` Remove-Item sweep | `find` + `rm` |
| `install_lua_zip` | `Expand-Archive` | `unzip -o -q` |
| `RestartSteam` | `cmd.exe /C restart_steam.cmd` | `bash restart_steam.sh` (steam -shutdown + relaunch detached) |
| `OpenGameFolder` | `explorer "..."` | `xdg-open` |
| `OpenExternalUrl` | `rundll32 url.dll,FileProtocolHandler` | `xdg-open` |
| `detect_steam_locale` | `Advapi32!RegGetValueA` on HKCU\Software\Valve\Steam | parse `~/.steam/registry.vdf` |
| `on_frontend_loaded` | `\\steamui\\LuaTools\\` literal paths | path joining via `platform.join` |

Path separator handling is also a touchpoint: literal `"\\"` in
upstream is replaced by `pjoin(...)` (which calls `platform.join`),
so the same `main.lua` works on both platforms once the matching
overlay loads.

### What's stubbed vs. complete on Linux

| Surface | Status | Notes |
|---|---|---|
| Add via LuaTools (download + install Lua + manifests) | complete | curl + unzip, drops files in `config/stplug-in/` and `depotcache/`. Lua packs that ship only the .lua trigger an automatic binary `.manifest` prefetch from `manifest.steam.run` + Steam CDN so first-install works without the slsteam-moon hook. |
| Restart Steam | complete | shutdown + relaunch, detects slsteam-moon launcher |
| Locale detection (Steam UI language → LuaTools translations) | complete | parses registry.vdf |
| Open game folder | complete | xdg-open |
| External URL opening | complete | xdg-open |
| Lua-script enumeration (`GetInstalledLuaScripts`) | complete | scans `config/stplug-in/` |
| Game install path lookup (`GetGameInstallPath`) | complete | parses `appmanifest_<id>.acf` across all library roots |
| Apply / Unfix Game Fix | **stubbed** | most fixes are Windows .dll/.exe drop-ins; per-fix Proton handling needs design first. See `linux/backend/platform/workers/fix_worker.sh` |
| `GetInstalledFixes` | **stubbed** | fix-history layout TBD |

## Build

Requirements: bash, unzip, curl (runtime). LuaJIT in `$PATH` is used
for syntax-checking during build, and recommended (Millennium ships
its own anyway).

```bash
scripts/build.sh
# → dist/luatools/  (drop into Millennium's plugins dir)

scripts/build.sh --zip
# → dist/luatools-linux.zip  (release artefact)
```

Install (path varies — Millennium reads from a per-user plugins
directory; check Millennium's settings for the absolute path on your
machine):

```bash
cp -R dist/luatools  ~/.local/share/Steam/steamui/skins/Millennium/plugins/
```

Then restart Steam. The plugin's `on_load` populates
`<steam>/steamui/LuaTools/` automatically.

## Rebasing onto a new upstream

When skyflarefox publishes a new luatools.zip:

```bash
scripts/rebase-upstream.sh /path/to/new/luatools.zip
# or
scripts/rebase-upstream.sh --url https://.../luatools.zip
```

The script:
1. Snapshots the current `upstream/luatools/backend/main.lua` as the
   merge base.
2. Replaces `upstream/luatools/` with the new zip.
3. Three-way merges (`git merge-file --diff3`) so the
   `-- ADAPT-LINUX:` edits are preserved while upstream's other
   changes flow in.
4. Leaves conflict markers in `shared/backend/main.lua` if any
   touchpoint can't be reapplied cleanly. Resolve, run
   `scripts/build.sh`, commit.

The rebase script also strips runtime artefacts (`temp_dl/`,
`lua_runtime.log`, etc.) from the vendored snapshot so the diff stays
clean.

## Credits

- LuaTools (Windows, original): [madoiscool](https://github.com/madoiscool/ltsteamplugin),
  current maintainer / fork [skyflarefox](https://github.com/skyflarefox/plugin)
- LuaToolsLinux (1.x, Accela-based): [StarWarsK](https://github.com/Star123451)
  & [geovanygrdt](https://github.com/gr33dster-glitch); referenced for the
  path-resolution patterns and SLSsteam wrapper detection.
- Millennium framework: [SteamClientHomebrew](https://github.com/SteamClientHomebrew/Millennium)
- slsteam-moon (`.so` engine this plugin talks to):
  [nwrafael/slsteam-moon](https://github.com/nwrafael/slsteam-moon)

See `LICENSE-NOTICE.md` for upstream licensing.
