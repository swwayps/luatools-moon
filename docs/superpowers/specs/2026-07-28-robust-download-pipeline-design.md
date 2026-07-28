# Robust Download Pipeline Design

**Date:** 2026-07-28
**Status:** Approved for implementation planning

## Summary

LuaTools will replace its shared, AppID-keyed download scratch space with a
transactional job model. Every configured source, including user-defined
sources, will be handled identically. The coordinator will combine all valid
data received within a bounded adaptive window and install the best usable
aggregate instead of failing because an optional source, DLC, or manifest is
missing.

The key success rule is:

> A usable base game is required. DLC keys and additional manifests improve
> the result, but their absence never invalidates an otherwise usable result.

The existing deterministic Lua parsing, key conflict handling, manifest
parsing, and atomic publication in `smart_merge.lua` remain the foundation.
The design strengthens their inputs and separates validation from publication.

## Goals

- Prefer a usable partial result over an avoidable failure.
- Combine complementary data from every source that completes in time.
- Treat built-in and custom sources with the same rules and time budgets.
- Do not require every DLC to have a key or manifest.
- Select the newest valid manifest available for each depot.
- Prevent duplicate workers, stale state writes, and repeated finalization.
- Make cancellation stop the real worker and its transfers.
- Preserve the precise cause of transport, archive, semantic, and publication
  failures.
- Safely handle downloaded archives and bound their resource use.
- Reuse one game-data pipeline for parallel and manual source selection.
- Separate game-data installation from applying game fixes to an existing game
  directory.

## Non-goals

- Assigning special trust, timeout, or priority rules to a source by name.
- Requiring complete DLC coverage before installing the base game.
- Waiting indefinitely for a source after a usable aggregate exists.
- Rewriting the validated parser and atomic publication logic without need.
- Migrating in-flight jobs created by an older plugin build. An update already
  requires the user to restart the plugin environment.

## Current Failure Model

The current fast worker calls a package usable when transport succeeds, the
expected HTTP status is returned, the archive lists one `<appid>.lua`, and
extraction succeeds. It does not inspect the Lua semantically. A weak package
can therefore count as success and cause a slower useful source to be stopped.
The later Lua finalizer can then reject the only retained package.

All source workers share AppID-keyed state and extraction paths. Cleanup occurs
before the worker lock, so a duplicate worker can erase the active worker's
files before it loses the lock. Polling can also invoke finalization more than
once because reading a ready state does not atomically claim it.

Errors from unrelated phases are collapsed into two generic messages. A
successful HTTP response containing an invalid package can be reported as a
connection problem. A local path, permission, disk, or rename failure can be
reported as invalid game data.

The manual worker has the same shared-path and finalization problems. Its
command construction also interpolates source-controlled URL text into a shell
command. The fixes path reuses that worker to extract directly into the game
directory, scans that entire directory for nested archives, and can process or
delete archives that were already present before the job.

## Architecture

### 1. Job coordinator

The backend owns a job keyed by `(appid, runId)`. Starting a job creates a
private directory such as:

```text
downloads/runs/<appid>/<runId>/
  job.json
  state.json
  stop
  sources/
    0000/
      response.part
      response.archive
      extracted/
      result.json
```

The per-AppID lock is acquired before any AppID-related mutation. If a live job
already exists, a duplicate start returns that job rather than launching a new
worker. No job removes another job's directory.

Every state update includes `runId`. The backend ignores state from an older
run. State files are written to a temporary file and atomically renamed.
Terminal states are immutable.

### 2. Transport worker

The shell worker is responsible only for transport and archive staging. It
does not decide whether game data is semantically usable and does not publish
files into Steam paths.

The backend writes source URLs and headers into a mode-0600 job file. The shell
command receives only a trusted generated job path, so source text is never
interpolated into shell syntax. Credentials remain outside the command line.

Each source has independent limits:

- connection timeout;
- first-byte/inactivity timeout;
- absolute transfer deadline;
- maximum compressed bytes.

The initial Linux game-data defaults are a 20-second connection limit, a
120-second first-byte/inactivity limit, and a 600-second absolute transfer
limit. These limits apply equally to built-in and custom sources and remain
overrideable in the test harness.

A source failure does not stop peers. Before a usable aggregate exists, the
coordinator waits until each source succeeds or reaches its own terminal
limit. There is no short global failure deadline.

### 3. Safe archive gate

Before extraction, a shared archive gate validates integrity and rejects:

- absolute paths and parent traversal;
- alternate path separators that change path meaning;
- symbolic links, hard links, device nodes, sockets, and other special files;
- duplicate or case-colliding target paths;
- reserved coordinator metadata names;
- excessive entry count, expanded bytes, or compression ratio.

Extraction occurs only inside the run directory. Source name, configured
order, and transport metadata are kept in `result.json`, outside the archive's
namespace.

An invalid entry invalidates that archive, but an invalid manifest inside an
otherwise safe archive does not invalidate valid Lua keys from the same source.

### 4. Semantic evaluator

`smart_merge.lua` gains a pure evaluation step separate from publication. It
parses all completed, safe source trees and returns:

- recognized app declarations;
- valid 64-hex depot keys;
- valid manifest references;
- fully parsed manifest candidates;
- conflicts and contributors;
- base-game viability;
- a quality vector describing aggregate improvements.

Data is merged by valid item, not by all-or-nothing source acceptance. A source
may contribute a key even when one of its manifests is corrupt. A source may
contribute complementary keys without declaring the requested app, provided
the aggregate contains a valid declaration for the requested app from at least
one source.

Arbitrary Lua statements remain discarded. Only recognized declarations,
keys, and manifest references are emitted.

## Base-game viability and optional content

The evaluator classifies appinfo depots when cached appinfo is available:

- **Base content depot:** content-bearing depot without `dlcappid`.
- **DLC content depot:** content-bearing depot with `dlcappid`.
- **Virtual DLC:** DLC entry without a content manifest; no depot key is
  expected.
- **Relevant platform depot:** Linux, Windows/Proton, or untagged/shared.
- **Irrelevant platform depot:** macOS-only on the Linux target.

An aggregate is usable when:

1. it declares the requested app; and
2. it contains a valid key for at least one relevant base content depot.

When appinfo is absent, token-limited, or contains no classifiable base depots,
the fallback criterion is a requested-app declaration plus at least one valid
depot key. This preserves the existing synthesized-depot recovery path.

The following are never success requirements:

- a key for every base platform variant;
- any macOS-only depot;
- every DLC app declaration;
- a key for every DLC content depot;
- a key for a virtual DLC;
- a manifest for every key or every appinfo GID.

Missing optional content reduces completeness but does not turn a usable base
aggregate into failure. Downstream depot pruning continues to remove content
that has no usable key and to omit unsupported content DLCs.

## Source-agnostic adaptive aggregation

Every enabled source is launched concurrently and evaluated with the same
rules. Configured order is metadata, not a transport preference.

The coordinator maintains the union of valid completed contributions. It does
not choose a single winning source. A base key from one source and a DLC key or
manifest from another can coexist in the final result.

Before the aggregate is usable:

- no source is stopped because another archive merely looks structurally
  correct;
- all sources continue until terminal success or their individual limits.

When the aggregate first becomes usable:

1. start a bounded enrichment window;
2. retain peers that are actively making byte progress;
3. merge every newly completed valid contribution;
4. reset a short quiet timer whenever the aggregate quality improves;
5. finish immediately when all peers are terminal;
6. finish after the quiet timer when no productive peer remains;
7. finish at the hard enrichment deadline even if a peer is still slow.

The initial policy waits at least two seconds after first usability, treats a
peer as productive when its byte count increased within the preceding two
seconds, and finishes after 500 milliseconds of no aggregate improvement when
no productive peer remains. Eight seconds after first usability is the hard
enrichment limit. Tests use an injected clock so these rules are deterministic
rather than dependent on scheduler timing.

The aggregate quality vector is monotonic and used only to recognize useful
new data:

1. usable base-game state;
2. number of relevant base depot keys;
3. number of DLC depot keys;
4. number of valid depot manifests for depots keyed by the aggregate;
5. number of additional recognized app declarations.

Source identity is absent from this vector. Configured order participates only
in deterministic conflict tie-breaking after exact data and consensus.

## Manifest policy

All valid manifest candidates in the available scope are grouped by depot. The
available scope includes validated manifests collected by the current job and
validated local archived manifests that can be associated with a depot in the
requested app or with a key in the aggregate.

For each depot, selection follows this order:

1. greatest manifest metadata `creation_time`;
2. when creation time ties, the current public GID from appinfo;
3. configured source order;
4. source index and numeric GID for deterministic final tie-breaking.

A corrupt, truncated, depot-mismatched, or GID-mismatched manifest is ignored
individually. Missing manifests never invalidate valid keys. The selected
manifest is archived and marked preferred exactly once during atomic
publication.

This policy selects the newest valid manifest for every depot from all data
available to the job without requiring complete depot or DLC coverage.

## State machine and single-flight finalization

The job state machine is:

```text
queued -> downloading -> evaluating -> ready -> processing -> done
                    \-> failed
                    \-> cancelling -> cancelled
```

`ready -> processing` is an atomic claim guarded by the AppID job lock. Pollers
only reconcile and observe state; at most one caller can finalize. A late
worker update cannot change `processing`, `done`, `failed`, or `cancelled` for
the active run.

The state snapshot contains:

```json
{
  "schemaVersion": 2,
  "runId": "...",
  "status": "downloading",
  "bytesRead": 0,
  "totalBytes": 0,
  "sources": {},
  "aggregate": {
    "usable": false,
    "baseKeys": 0,
    "dlcKeys": 0,
    "manifests": 0
  },
  "error": null
}
```

Per-source state records phase, curl result, HTTP status, bytes, archive result,
semantic contributions, and a structured error. The frontend may summarize
these fields but does not determine success.

## Cancellation

The worker records its PID and process group in the run. Cancellation:

1. atomically changes the active job to `cancelling`;
2. writes the run stop marker;
3. signals the worker process group;
4. waits for curl and parser processes to be reaped;
5. removes only that run directory;
6. commits terminal state `cancelled`.

The frontend shows cancellation only after backend acknowledgement and keeps a
single poller registry keyed by AppID/runId.

## Manual source mode

Manual source selection uses the same coordinator with a one-source candidate
set. It therefore receives the same archive validation, semantic acceptance,
state identity, cancellation, publication, and error behavior. The legacy
game-data use of `downloader.sh` is removed rather than maintained as a second
implementation.

## Game-fix downloads

Game-fix application uses the common transport and archive gate but has a
separate consumer. It never extracts directly into the game directory.

The fix consumer:

1. extracts primary and supported nested archives into private staging;
2. derives DLL and launcher metadata only from files in that staging tree;
3. never scans or deletes pre-existing archives in the game directory;
4. builds an explicit overlay plan;
5. snapshots every destination that will be replaced;
6. applies staged files with checked writes/renames;
7. restores snapshots if any publication step fails;
8. reports success only after the entire overlay commits.

Nested archive failure is a real archive-phase error, not ignored success. The
existing authentication header handling, progress reporting, DLL inventory,
and launcher inventory behavior is preserved.

## Error model

Terminal failures use stable codes and phases:

- `configuration/no_sources`
- `transport/dns`
- `transport/connect_timeout`
- `transport/inactivity_timeout`
- `transport/absolute_timeout`
- `transport/http_status`
- `archive/invalid`
- `archive/unsafe_entry`
- `archive/resource_limit`
- `semantic/wrong_app`
- `semantic/no_usable_base_key`
- `publish/steam_path`
- `publish/permission`
- `publish/no_space`
- `publish/write`
- `publish/rename`
- `cancelled/user`

A whole job fails for source/data reasons only after every source is terminal
and the aggregate is still unusable. Publication errors remain distinct from
source errors. Human-readable messages are derived from the structured cause;
they never replace it.

## Preservation of working behavior

The implementation must retain:

- clearing Steam Runtime loader variables before system tools run;
- one GET per source body;
- authenticated headers outside process arguments;
- monotonic byte progress and atomic snapshots;
- parallel source collection;
- deterministic union of complementary keys;
- consensus and configured-order conflict resolution;
- strict full-manifest parsing;
- newest-manifest selection per depot;
- archive of selected valid manifests;
- atomic Lua/manifest publication with rollback;
- acceptance of valid Lua without manifests;
- acceptance of partial manifest coverage;
- manual selection through the same validated finalizer;
- nested fix archives and generated DLL/launcher inventories.

## Test strategy

Implementation begins with failing reproductions for every confirmed defect.

### Aggregation and semantics

- Fast minimally usable source plus stalled peer installs successfully.
- The same result holds with source order reversed.
- A custom source can be the sole usable contributor.
- A structurally valid but keyless source cannot stop a slower usable peer.
- Complementary base and DLC contributions from different sources are united.
- Missing DLC key does not fail a usable base game.
- Virtual DLC without a key does not count as missing.
- macOS-only missing data does not delay Linux success.
- Invalid manifest is ignored while valid Lua keys from its source survive.
- Missing all manifests still permits a usable key-only result.
- Appinfo-missing fallback accepts an app declaration plus a valid key.

### Manifest selection

- Newest valid `creation_time` wins for each depot regardless of source order.
- Different depots select their newest candidates independently.
- Current public GID wins only when creation times tie.
- Corrupt, truncated, wrong-depot, and wrong-GID candidates are excluded.
- A validated local archived candidate participates in selection.
- Tie-breaking is deterministic across filesystem enumeration orders.

### Concurrency and lifecycle

- Two starts for one AppID create one active job.
- A duplicate start cannot remove active extraction.
- An old run cannot overwrite a new run's state.
- Concurrent status calls execute finalization exactly once.
- A late worker failure cannot overwrite `done`.
- Cancel terminates curl and the worker group before reporting `cancelled`.
- State remains valid JSON during rapid polling.

### Transport and archive safety

- URLs containing shell metacharacters are passed as data and execute nothing.
- HTTP 200 with HTML, corrupt ZIP, and missing app Lua are distinct outcomes.
- Absolute paths, traversal, links, special files, collisions, and reserved names
  are rejected before extraction.
- Entry, expanded-size, compressed-size, and ratio limits are enforced.
- Connection, inactivity, and absolute transfer limits are independently tested.

### Game-fix application

- Pre-existing archives in the game directory remain untouched.
- Nested processing considers only the current staging tree.
- A nested archive failure cannot report success.
- Mid-publication failure restores every replaced destination.
- Successful application preserves DLL and launcher inventory behavior.

### Regression suite

All existing downloader, smart merge, finalization, deduplication, authentication,
fix overlay, packaging, and build-output tests must pass. Timing-sensitive tests
will use controllable fixture state rather than narrow wall-clock assumptions.

## Completion criteria

The work is complete when:

1. all confirmed failure reproductions pass;
2. the existing regression suite passes;
3. source names do not appear in policy decisions;
4. a usable base result succeeds despite optional-source or optional-DLC
   failures;
5. every terminal error preserves its exact phase and code;
6. manual, parallel, and custom-source game-data jobs share one coordinator;
7. fix payloads stage and roll back without scanning unrelated game files.
