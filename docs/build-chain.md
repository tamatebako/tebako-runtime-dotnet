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
the repack scope), called by the thin triggers (`build-linux-gnu.yml`,
`build-linux-musl.yml`, `build-macos.yml`, `build-windows.yml`).
Stages:

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
3. **preflight** — the container digest pins (the ruby#381 idiom, the
   php factory's grammar): contract.yml's `container_digests` must
   equal the registry's CURRENT digest for `container_version` — per
   (container × leg arch), read through ghcr's anonymous-token flow —
   before any leg spends compute. A retagged toolchain container under
   an unchanged tag fails HERE, never mid-leg.
4. **build** — one leg per (.NET SDK × arch): `tools/build_runtime` →
   `tools/boot_smoke` → the `runtime-packages-<os>-<arch>-<dotnet>`
   artifact. Leg shapes:
   - **linux-gnu** — runner-native on ubuntu-24.04 (its image carries
     ruby, libicu74, libssl3: the muxer's own deps).
   - **linux-musl** — the container-leg idiom (the php/openjdk
     grammar): the gnu host docker-runs the digest-pinned
     `tpkg-builder-x86_64-linux-musl` image per step — the pinned musl
     binaries (wrapper, tfs) and the staged musl SDK execute only under
     musl libc, and build_runtime's extracted smoke + the boot smoke
     execute them. alpine carries no libicu by default (the .NET
     runtime's one non-baked host dep), so the in-container steps
     `apk add icu` — the gnu runner's preinstalled libicu74's musl
     mirror.
   - **macos** — runner-native (macos-15, macos-15-intel) with an
     explicit setup-ruby (the system ruby predates the tooling's
     floor). NO macOS deployment floor rides here: the floor is a
     compile-time concern (clang stamps `LC_BUILD_VERSION` per
     invocation — the php/ruby factories ride
     `MACOSX_DEPLOYMENT_TARGET` through their whole build) and a repack
     compiles nothing; the wrapper exe + tfs CLI carry the product
     repo's floor, Microsoft's binaries carry Microsoft's.
   - **windows** — runner-native on the openjdk ucrt idiom: the x64 leg
     (windows-latest) sets up msys2 ucrt64 for bsdtar (GNU tar cannot
     read the `.zip` SDK archive); the arm64 leg (windows-11-arm)
     extracts with the in-box System32 tar.exe and sets nothing up.
     The build step runs a closed PATH (the toolchain dirs only, plus
     the hosted ruby's own dir — the openjdk grammar; setup-ruby
     publishes no windows-arm64 build, so the legs ride the runners'
     hosted ruby). Both legs then run the spec 34 §8.2 signing lane
     (below) between the build and the boot smoke.
5. **verify** — the terminal aggregate and the branch-protection gate
   (the build legs are a dynamic matrix whose check names shift with
   the catalog, so protection pins this job's stable check name).

`lint.yml` is the static gate (no builds): the same contract check, the
catalog/matrix resolution, a `ruby -c` sweep over every authored ruby
file, and a parse pass over every authored YAML/JSON.

There is NO publish stage (the publish pipeline is its own increment):
the release shard (`<stem>.manifest.json`), the `.sha256` sidecars, and
the blksum sidecar are already emitted in-leg so the increment is a
consumption change, never a build-shape change. The windows signing
lane (below) re-anchors the wrapper's sidecar + shard from the SIGNED
bytes in-leg, so the future publish ships sign-then-hash by
construction.

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

## The windows signing lane (spec 34 §8.2)

The python/ruby factories' Azure Trusted Signing lane, mirrored at this
factory's repack scope, in-leg between the build and the boot smoke —
so the smoke exercises the SIGNED bytes (the on-platform proof) and the
upload ships them. Both windows legs arm (`matrix.os == 'windows'` —
the matrix grammar keys on os, never the arch; x86_64-windows-ucrt and
aarch64-windows-ucrt alike).

- **Sign target**: exactly ONE host-level PE — the wrapper exe
  (`<stem>.exe`). The .NET SDK lives INSIDE the `.tfs` env image, so no
  loose DLL rides the release tier (the jruby grammar, not python's
  exe+libpython-DLL pair); the in-image PEs are Microsoft's own signed
  binaries, mounted never extracted.
- **The arm check** (`ci/windows-sign-gate.sh`, gated on the
  `WINDOWS_SIGNING_ENABLED` repo variable): armed but a secret/variable
  unresolved is a fast named failure BEFORE any signing call (spec 34
  §7.5); gate off, every sign step skips and the leg ships unsigned
  byte-identically (spec 00 invariant 7 — §7.4 gate-off parity, a loud
  notice).
- **The chain**: the sign-staging COPY (the action enumerates by
  EXTENSION, so only the staged `.exe` is in scope — the `.tfs` and the
  sidecars never enter `files-folder`) → OIDC `azure/login` in the
  `windows-signing` environment (the job-level
  `permissions: {contents: read, id-token: write}` is the OIDC boundary;
  the environment must NEVER gain required reviewers — every platform's
  legs share the build job) → the TrustedSigning module preflight →
  `Azure/artifact-signing-action` (SHA256 digests + the mandatory
  RFC 3161 countersignature, `http://timestamp.acs.microsoft.com`) →
  the pwsh verify, which moves the signed bytes BACK over the contract
  path and runs `signtool verify /pa /v` + `Get-AuthenticodeSignature`
  (must be Valid with a TimeStamperCertificate) there.
- **Sign-then-hash (spec 34 §1.3), this factory's shape**: the repack
  computes the wrapper's `.sha256` sidecar + the release shard's digest
  INSIDE `tools/build_runtime` (there is no publish-time uploader yet —
  pre-release), so the verify step RE-ANCHORS both from the signed
  bytes before the boot smoke and the upload. The shard's recorded
  filename is checked against the contract name — a stem-computation
  drift fails closed.

## The boot smoke (tools/boot_smoke)

The post-build acceptance gate (stdlib-only; scenarios in the tool's
header). Every leg runs the SAME set — the windows legs included, where
the PE/ucrt materialize path IS the boot under test:

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
- `compute-floor` — tebako-runtime-python#79's lesson, the php
  factory's shape: a boot-only gate ships a leg that computes at a
  fraction of the matrix's rate. A small C# probe builds inside the
  pair, then times a fixed recursive fib(35) with `Stopwatch` INSIDE
  the process (best of three — boot/mount cost and one-off scheduling
  noise never enter the measurement) against a per-platform ceiling
  (`COMPUTE_FLOOR_SECONDS` in the tool — a regression tripwire, never
  a benchmark bound; a platform with no recorded ceiling is a named
  error). The probe also reports
  `RuntimeInformation.ProcessArchitecture` — the repack's slow-compute
  class is a pair transplanted under emulation (an x64 muxer on an
  arm64 leg), so the process architecture must be the leg's OWN. Mode
  is `COMPUTE_FLOOR_MODE`: `fail` (the default) trips the leg on a
  breached floor; `warn` — armed by the workflow on the macos-x86_64
  leg ALONE, where the link-unit line carries the live tebako#1095
  slow-compute defect on real Intel silicon — prints a `::warning::`
  and keeps the leg green. REMOVAL CONDITION: the macos-x86_64 leg
  reverts to fail-closed when tebako#1095 closes.
- `bad-mount` — an unavailable payload image exits 69 naming the image.
- `mount-root-malformed` — a relative `TEBAKO_MOUNT_ROOT` exits 65.
- `override-ungranted` — an absolute `TEBAKO_MOUNT_ROOT` against the
  dotnet image exits 78 (the image grants no override — the closed
  default).

Every scenario runs with a scrubbed env (no inherited `TEBAKO_*` /
`DOTNET_*` / `LD_*` / `DYLD_*`), a scratch HOME + NuGet cache, and a
stable scratch TMPDIR (the driver-named exec cache materializes once
per smoke run). The CLI noise knobs (`DOTNET_CLI_TELEMETRY_OPTOUT`,
`DOTNET_NOLOGO`, `DOTNET_SKIP_FIRST_TIME_EXPERIENCE`) are always set.
On windows the scrub additionally forces every boot's PATH to the
Windows system directories (System32 + the Windows root + Wbem — the
audience-rule condition, the python factory's grammar), and the
hermetic roots ride the native spellings (USERPROFILE for the CLI home,
TMP/TEMP for the exec cache — native windows processes ignore
HOME/TMPDIR).

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

Born pinned: both input pin layers above, the container line
(`container_version` the moving family tag + `container_digests` the
immutable per-arch ghcr manifest digests — the preflight proves
recorded == live before any leg spends compute), and
`SOURCE_DATE_EPOCH` follows the ruby#381 idiom (the compute job derives
ONE epoch from the HEAD commit under a full-history checkout; every leg
stamps it into the image manifest's `identity.created`, so a
same-commit re-run stamps identically). The stamp is fail-closed: a
malformed `SOURCE_DATE_EPOCH` is a named build error (exit 64), never
a silent wall-clock fallback; unset falls to epoch 0 (the tfs-cli
mkimage convention), so a local build is deterministic too.

## Where each value lives (SSOT)

- Contract version + product-line pin + toolchain digests + container
  line + version catalog: `contract.yml` (+ `schema/contract.schema.yml`).
- SDK url/sha256/sha512 pins per triplet: `versions.yml` (cross-locked
  to the catalog and to the matrix legs by
  `scripts/check_contract.rb`).
- Env vocabulary (host/os/arch/container/tar): `.github/matrix.json`.
- The triplet ↔ asset-platform ↔ RID grammar:
  `build/lib/tebako_dotnet_builder/platform.rb` (mirroring tpkg's
  owner-side tables).
- The prune policy: `build/lib/tebako_dotnet_builder/image_builder.rb`.
- The boot-contract scenarios + the compute-floor ceilings:
  `tools/boot_smoke`.
- This architecture: `docs/build-chain.md`.
