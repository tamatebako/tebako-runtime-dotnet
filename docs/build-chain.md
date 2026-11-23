# The build chain — architecture and invariants

This document is the normative description of how this repository's CI
turns Microsoft's pristine per-RID .NET SDK archive into a verified
runtime pair, and of the pin contracts that keep the skeleton honest.
**If you change any workflow, the build tooling, the matrix
computation, the prune policy, or a cache key, update this file in the
same PR.** A future agent that skips this file and "just fixes" a red
run is the classic failure mode — read it first.
(tebako-runtime-php's docs/build-chain.md is the direct template;
tebako-runtime-ruby's is the ecosystem reference.)

## The shape decision (read before anything else)

This factory is a **repack** (the openjdk/node grammar, never the
php/ruby source-build grammar): Microsoft publishes compiled per-RID
.NET SDK builds; nothing compiles here. Two consequences shape
everything below:

1. **The driver link is the spec-29 wrapper, consumed.** The runtime
   pair's exe is `tebako-runtime-launcher` — the tebako-owned process
   entry point with the spec-17 driver embedded — downloaded
   sha256-verified from the pinned tamatebako/tebako release. The
   driver cannot be linked into bytes tebako did not compile (the
   `dotnet` muxer), and the alternatives lose on evidence (README's
   host-model section): a custom `hostfxr` apphost authors new native
   code and would have to reimplement the muxer's SDK-resolution
   surface; chaining one to the real muxer is the wrapper with extra
   steps. `hostfxr` hosting is the app-payload increments' question,
   not the pair's.
2. **Visibility is exec-cache, declared.** The muxer self-locates its
   home (`host/fxr`, `sdk/` bands, `shared/` frameworks) from its own
   exe path and dlopens its host stack from that tree — under
   exec-cache the whole tree is host-real (the openjdk precedent). The
   preload tier is the named future refinement, gated on measurements;
   the exec-cache first-boot materialization (~0.5 GB, content-keyed)
   is the recorded cost.

## The staged hierarchy

One reusable workflow, `_build-platform.yml` (the php factory's port at
the repack scope), called by the thin triggers (`build-linux-gnu.yml`
today). Stages:

1. **parity** — the contract gate's driver-source parity arm needs the
   pinned release's `lib.rs` off raw.githubusercontent.com, a fetch
   that flakes under near-simultaneous per-platform reads
   (tamatebako/tebako-runtime-python#4). ONE job fetches it (bounded
   retry) and hands it to compute as an artifact.
2. **compute** — the contract gate (`scripts/check_contract.rb`:
   contract.yml against `schema/contract.schema.yml`, the
   catalog ↔ versions.yml cross-lock, the matrix-leg coverage arm, and
   the parity arm reading the stage-1 artifact via `TEBAKO_DRIVER_SRC`)
   runs first; then `scripts/compute_matrix.rb` expands this platform's
   legs from `contract.yml`'s catalog × `.github/matrix.json`'s env
   vocabulary under the dispatch filters. Every downstream value flows
   from these outputs — workflow YAML never hardcodes a version, a tag,
   or a SHA. The run's `SOURCE_DATE_EPOCH` (the HEAD commit's epoch,
   the ruby#381 idiom) is computed here and exported to the legs.
3. **build** — one leg per (.NET SDK × arch): `tools/build_runtime` →
   `tools/boot_smoke` → the `runtime-packages-<os>-<arch>-<dotnet>`
   artifact. The legs run **runner-native** (a repack compiles nothing
   — no tpkg-builder container exists in this repo; the leg needs only
   the runner's ruby/curl/tar plus the .NET muxer's own runtime deps,
   which ubuntu-24.04 carries).
4. **verify** — the terminal aggregate and the branch-protection gate
   (the build legs are a dynamic matrix whose check names shift with
   the catalog, so protection pins this job's stable check name).

`lint.yml` is the static gate (no builds): the same contract check, the
catalog/matrix resolution, a `ruby -c` sweep over every authored ruby
file, and a parse pass over every authored YAML/JSON.

There is NO publish stage (the publish pipeline is its own increment):
the release shard (`<stem>.manifest.json`), the `.sha256` sidecars, and
the blksum sidecar are already emitted in-leg so the increment is a
consumption change, never a build-shape change.

## The inputs (all pinned, all verified)

- **the .NET SDK archive** — `builds.dotnet.microsoft.com`'s per-RID
  `dotnet-sdk-<v>-<rid>.{tar.gz,zip}`, sha256-pinned per (version ×
  triplet) in `versions.yml`. Microsoft's own published digest is
  sha512 (the 10.0 channel's releases.json); each recorded sha256 was
  computed at pin time from bytes first verified against it, and the
  sha512 rides the pin as `upstream_sha512` (the provenance record).
  `Fetcher.download` verifies at fetch time; a mismatch is a named
  error after a bounded retry, never a refetch loop.
- **the tebako toolchain** — `tebako-runtime-launcher-<line>-<pid>`,
  `tfs-<line>-<pid>`, and (POSIX) `link-unit-<line>-<pid>.tar.gz` from
  the pinned tamatebako/tebako release (`contract.yml
  link_unit_release`), each verified against its `tools.sha256` pin;
  the wrapper and tfs pins are additionally cross-checked against the
  release's own SHA256SUMS (both anchored). The link-unit tarballs are
  not in that monolith, so their recorded pin is the single anchor.
  An empty pin, a missing asset, or a checksum mismatch are hard named
  errors — this factory has no source-build path for the driver stack.

Downloads land in `.build/downloads/` and are re-verified against the
pins on every use, so a poisoned or stale cache entry cannot survive a
pin bump.

## The repack flow (tools/build_runtime)

1. **fetch + verify** — the SDK archive and the toolchain (above).
2. **stage + prune** — extract the archive pristine (the SDK tree
   extracts flat, no strip), assert the tree shape, then prune to the
   declared scope. The policy
   (`build/lib/tebako_dotnet_builder/image_builder.rb`, mirrored in
   README.md): keep the muxer, `host/fxr/`, `shared/Microsoft.NETCore.App`,
   the `Microsoft.NETCore.App.Ref` + per-RID `…Host.<rid>` packs (the
   offline compile closure), `sdk/<band>/` whole, `sdk-manifests/`,
   `templates/`, the license carriage; prune
   `shared/Microsoft.AspNetCore.App` + `packs/Microsoft.AspNetCore.App.Ref`
   (the web workload increment) and `sdk/<band>/TestHostNetFramework`
   (the windows-only legacy test host). Every pruned path is asserted
   ABSENT and every kept path PRESENT — an SDK bump whose tree drifted
   is a named build error (exit 103), never a silent scope change.
3. **the POSIX shim** — `lib/tebako/libtfs_preload.so` (from the link
   unit) rides the image so the layout's `preload_shim` grant lets the
   jail's host-IO binding survive the exec into the muxer (the openjdk
   grammar; declared-but-absent is exit 78, so the build stages the
   file in the same pass). The windows image omits the grant (no
   preload mechanism there).
4. **the two cards** — `/__tpkg__/manifest.yaml` (kind runtime, engine
   dotnet, implementation dotnet, `home: "/"` — the exec-cache
   whole-tree trigger; the spawn surface is the single `dotnet`
   entrypoint: every SDK verb is `dotnet <verb>`) and
   `/lib/tebako/layout.yaml` (era 2, `interpreter: /dotnet[.exe]`,
   `visibility: exec-cache`, no `mount_root_override` grant — the
   closed default, pinned by the boot smoke's exit-78 scenario).
   `identity.created` stamps the run's `SOURCE_DATE_EPOCH` (unset falls
   to epoch 0 — deterministic local builds).
5. **image** — `tfs mkimage --format limnifs` (the product default; the
   pinned tfs CLI, in-process — never a shell-out to system imagers)
   plus the `blksum` sidecar (spec 39 §3).
6. **pair + sidecars** — the wrapper exe (0755) beside
   `<stem>.tfs` under `runtime-packages/`, per-asset `.sha256`
   sidecars, the `<stem>.manifest.json` shard, and the
   `payload-<triplet>.yaml` release-tier manifest (the real blob sha).
7. **read-back** — the same tfs CLI re-reads the image: the embedded
   manifest exists and validates (`tfs info --json` carries no
   `manifest_error`), the layout card and the declared entrypoint
   resolve, and the pruned paths are absent.
8. **extracted smoke** — `tfs extract` on the host, `dotnet --info` on
   the extracted muxer: the pinned SDK version AND the carried
   Microsoft.NETCore.App version must both answer (a content check,
   never an exit-code check).

## The boot smoke (tools/boot_smoke)

The post-build acceptance gate (stdlib-only; scenarios in the tool's
header):

- `bare` — no `TEBAKO_RUNTIME_IMAGE`: the wrapper names the missing env
  image (the pair is two artifacts; a bare wrapper is a named error).
- `boot` — `--tebako-entry dotnet --info` off the pair: the pinned SDK
  version, the carried shared runtime, and the leg's RID all answer —
  the exec-cache materialization + the muxer's self-location proven end
  to end.
- `compile` — a hand-written `net10.0` console fixture (two files; no
  template restore): `dotnet run --project … -c Release` inside the
  pair — MSBuild + Roslyn + the OFFLINE framework resolution against
  the bundled packs — then the compiled app reports its own framework
  version + RID.
- `dll` — the fixture built to a dll and executed directly
  (`dotnet <dll>`) — the app-payload execution shape.
- `bad-mount` — an unavailable payload image exits 69 naming the image.
- `mount-root-malformed` — a relative `TEBAKO_MOUNT_ROOT` exits 65.
- `override-ungranted` — an absolute `TEBAKO_MOUNT_ROOT` against the
  dotnet image exits 78 (the image grants no override — the closed
  default).

Every scenario runs with a scrubbed env (no inherited `TEBAKO_*` /
`LD_*` / `DYLD_*`), a scratch HOME + NuGet cache, and a stable scratch
TMPDIR (the driver-named exec cache materializes once per smoke run).
The CLI noise knobs (`DOTNET_CLI_TELEMETRY_OPTOUT`, `DOTNET_NOLOGO`,
`DOTNET_SKIP_FIRST_TIME_EXPERIENCE`) are always set.

## The cache architecture

One cache, keyed on what it contains:

| Cache | Key | Contents |
|-------|-----|----------|
| verified downloads | `tebako-dotnet-dl-<os>-<arch>-<hash(contract.yml, versions.yml)>-v<CACHE_VER>` | `.build/downloads` (the sha256-verified SDK archive + wrapper + tfs CLI + link unit) |

`save-always: true` — a red boot smoke must never tax the next leg a
cold re-download. The key carries the pins' hashes, so a pin bump mints
a fresh entry and the stale one ages out. `CACHE_VER` stays the manual
escape hatch — bump ONLY for a build-recipe shape change under
UNCHANGED pins, and say why in the workflow comment.

## The determinism notes

Born pinned: both input pin layers above, and `SOURCE_DATE_EPOCH`
follows the ruby#381 idiom (the compute job derives ONE epoch from the
HEAD commit under a full-history checkout; every leg stamps it into the
image manifest's `identity.created`, so a same-commit re-run stamps
identically). The packed image's own metadata is deterministic the same
way (tfs-cli's mkimage honors the variable).

## Where each value lives (SSOT)

- Contract version + product-line pin + toolchain digests + version
  catalog: `contract.yml` (+ `schema/contract.schema.yml`).
- SDK url/sha256/sha512 pins per triplet: `versions.yml` (cross-locked
  to the catalog and to the matrix legs by
  `scripts/check_contract.rb`).
- Env vocabulary (host/os/arch): `.github/matrix.json`.
- The triplet ↔ asset-platform ↔ RID grammar:
  `build/lib/tebako_dotnet_builder/platform.rb` (mirroring tpkg's
  owner-side tables).
- The prune policy: `build/lib/tebako_dotnet_builder/image_builder.rb`.
- The boot-contract scenarios: `tools/boot_smoke`.
- This architecture: `docs/build-chain.md`.
