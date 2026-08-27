# Review Remediation Design

## Goal

Resolve every accepted functional, structural, integration, and commit-history finding from the review of the local commit stack and the five stored upstream commits, while preserving existing external protocol values.

## Scope

The implementation covers:

- confining cleanup operations to the install directory derived by the backend for the requested Steam AppID;
- applying one source-URL policy to manual entries, remote catalogue imports, persisted entries, availability probes, and download candidates;
- counting only abnormal Steam-client exit lines that are actually included in the diagnostic artifact;
- making the NixOS Lumen wrapper generation insensitive to whitespace normalization;
- centralizing Steam AppID and fix-ID validation used by the new lua.tools integration;
- centralizing the Lua category vocabulary and rank table while retaining external category strings unchanged;
- removing the duplicate `shell_quote` binding left by merge resolution;
- correcting the two non-conforming local commit messages without flattening the merge topology.

The review's terminology finding is excluded at the user's direction. External values and current code terminology remain unchanged.

## Design

### Domain values

Add `plugin/backend/lua_tools_domain.lua` as the single Lua boundary for:

- `positive_appid(value)`, accepting positive integral numbers and decimal-only strings;
- `fix_id(value)`, accepting the existing optional namespace plus UUID format;
- category membership and rank lookup.

The six lua.tools backend modules consume this helper instead of maintaining copies. The Python index generator retains its parser because it cannot import Lua, but its accepted categories and rank order are checked against the canonical Lua data by a repository test. This avoids introducing a build-time code generator merely to share a handful of constants across languages.

### Cleanup confinement

`UnFixGame` treats `installPath` as untrusted compatibility input. Before deleting legacy files, it calls `steam_utils.get_game_install_state(appid)` and then `steam_utils.game_library_path(state.installPath)`. Cleanup proceeds only when the derived path exists, belongs to a configured Steam library, and—when a caller supplied `installPath`—normalizes to the same path. A mismatch returns an error before clearing saved application state or modifying files.

### Source catalogue validation

`api_manifest.validate_source_url` remains the policy function: the URL must be HTTP(S), contain `<appid>`, contain no userinfo, whitespace, controls, or invalid authority. Remote entries are normalized through that function before being stored. Persisted custom/remote entries are revalidated when reconciled and again before being returned to download consumers, so an older malformed catalogue cannot bypass the new boundary.

Managed entries with no URL remain valid, and shipped built-ins continue to use their authoritative defaults. Invalid remote entries are skipped and counted only as rejected inputs; they are never persisted or handed to availability/download code.

### Diagnostics

The abnormal-exit collector builds the exact two-stage filtered stream first, writes its capped tail to the artifact, and increments the summary by the number of filtered matches rather than by the broader first grep. A debugger echo therefore contributes to neither output nor count.

### Installer integration

The NixOS shim is emitted with `printf '%s\n'` rather than an indentation-sensitive heredoc. Tests parse both the original installer and an `expand`-normalized copy.

### History hygiene

After all code and tests pass, rewrite only the local commit messages that violate project rules:

- give the merge commit an allowed Conventional Commit type;
- shorten the final revert body to two sentences.

The merge topology is preserved. Author and committer identity remain `unplausible <unplausible@noreply.codeberg.org>`, and rewritten author/committer dates are normalized to UTC. No remote operation is performed.

## Error handling

All safety checks fail closed. A cleanup path mismatch leaves both disk contents and saved state untouched. A malformed remote source is skipped without weakening other sources. Diagnostic collection remains best-effort and reports zero matches when no filtered line exists. Installer wrapper generation fails if its destination cannot be written.

## Testing

Implementation follows red-green-refactor cycles:

1. Extend endpoint guard tests with a hostile `UnFixGame` path and assert zero removals/state changes.
2. Extend catalogue tests with malformed remote entries and a malformed persisted entry.
3. Tighten diagnostic tests to require an exact abnormal-exit count in the presence of a debugger distractor.
4. Add/restore installer syntax coverage for whitespace-normalized input.
5. Add domain-value tests covering decimal-only AppIDs, namespaced fix IDs, and category ranks; update module tests to exercise the shared helper.
6. Run targeted tests after each fix, followed by `scripts/test-quick.sh`, `git diff --check` for both reviewed windows, the privacy scan, and normalized installer syntax validation.

## Non-goals

- No UI redesign or new source protocol.
- No changes to external category values or existing terminology.
- No remote fetch, push, release, or deployment.
- No broad refactor of the LuaTools backend outside the reviewed duplication.
