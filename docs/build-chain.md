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

   **The macOS dyld-stripping plane does not apply to this shape**
   (tebako#1117's dotnet cell — the verdict the macOS sign arm below
   ships). The stripping law is governed by the signature of the EXEC
   TARGET: a hardened-runtime image without
   `allow-dyld-environment-variables` loses `DYLD_INSERT_LIBRARIES` at
   exec on macOS 14 (the tebako-runtime-r#5 class). Two targets exist
   here, and neither's core IO depends on an insertion:
   - The **wrapper** (`tebako-runtime-launcher`, tebako-signed under
     the arm below): the driver's boot-head self-insert fires on macOS,
     but
     under exec-cache the wrapper only mounts, materializes, and execs
     — nothing in its process consumes the interpose dylib, so a
     stripped insertion costs nothing (the boot continues uninserted,
     loudly — the product's designed fallback; proven by the same
     product binary in the openjdk line running green on darwin-23
     hardened with NO entitlements embedded at all, and by this repo's
     macos legs, e.g. run 45540251881).
   - The **muxer** (Microsoft's own bytes, byte-identical from the
     pinned SDK): its core IO reads the materialized host-real SDK
     tree — no shim needed. The image's `preload_shim` grant serves
     only the jail's host-IO binding across the exec, and whether that
     insertion reaches the muxer is governed by MICROSOFT's signature,
     never this repo's profile: verified on the pinned
     10.0.404-osx-arm64 tree — the muxer is hardened-signed by
     Microsoft Corporation (UBF8T346G9) and carries
     `allow-dyld-environment-variables` itself, so the insertion is
     honored even on macOS 14.
   So the wrapper's `ci/runtime.entitlements` pair (below) carries no
   dyld grant for visibility; the question reopens only if the
   preload-tier refinement ever lands AND the insertion target changes
   to a tebako-signed exe (the python/php/r shape), which this repack
   factory never builds.

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
   the in-leg signing lanes (macos: spec 31's sign + notarize; windows:
   spec 34 §8.2's lane) → `tools/boot_smoke` → the
   `runtime-packages-<os>-<arch>-<dotnet>` artifact. Leg shapes:
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
     repo's floor, Microsoft's binaries carry Microsoft's. Both legs
     then run the spec 31 §5 sign + notarize arm (below) between the
     build and the boot smoke.
   - **windows** — runner-native on the openjdk ucrt idiom: the x64 leg
     (windows-latest) sets up msys2 ucrt64 for bsdtar (GNU tar cannot
     read the `.zip` SDK archive); the arm64 leg (windows-11-arm)
     extracts with the in-box System32 tar.exe and sets nothing up.
     The build step runs a closed PATH (the toolchain dirs only, plus
     the hosted ruby's own dir — the openjdk grammar; setup-ruby
     publishes no windows-arm64 build, so the legs ride the runners'
     hosted ruby). Both legs then run the spec 34 §8.2 signing lane
     (below) between the build and the boot smoke.
5. **publish** — gated on the coordinator's `publish` input (never on
   the build triggers): one job per leg, re-downloading the leg's
   immutable in-run artifact and publishing it through the
   tebako-release gem (pinned at `contract.yml release_tooling`,
   declared by `scripts/release_adapter.rb`) — the payload assets +
   the gem-rendered shard and sidecars, write-once per-leg names (spec
   13 §2a's de-rendezvous, tebako-runtime-ruby#161/#190) — then the
   gem's OpenPGP signer over every served name (spec 09 §5), then SLSA
   L3 provenance. The gem's publishable set accepts only payload
   assets + its known sidecars, so the in-leg shard +
   `payload-<triplet>.yaml` stage aside as build evidence first — the
   release's metadata is the gem's render off the served (signed)
   bytes, never a hand-off.
6. **verify** — the terminal aggregate and the branch-protection gate
   (the build legs are a dynamic matrix whose check names shift with
   the catalog, so protection pins this job's stable check name). On
   publish runs it gates on the publish legs too
   (tebako-runtime-ruby#190); audit runs (publish.yml's audit mode)
   build nothing and skip it.

`lint.yml` is the static gate (no builds): the same contract check, the
catalog/matrix resolution, a `ruby -c` sweep over every authored ruby
file, and a parse pass over every authored YAML/JSON.

The publish pipeline rides the same two files: `_build-platform.yml`
gains the per-leg `publish` job (above) behind the `publish`/`audit`
workflow_call inputs, and `publish.yml` is the operator-facing
coordinator (the r factory's port): a `force_rebuild` prepare-release
(tebako-runtime-ruby#189), the four platform fan-outs, then ONE release
job — the whole-matrix AUDIT (the gem's uploader under `AUDIT_ONLY`,
read-only) and the registry render (`tools/registry_update.rb`, off the
release's own shards — spec 04 §2's mirror) landed on main by bot PR +
auto-merge, followed by the official aggregate's nudge and the versions
catalog's ping. The registry keys are the composite `<sdk>-<tebako>`
grammar (one SDK ships on several tebako product lines — this factory's
release tag IS the pinned product line; the composite keeps every line
addressable). The `acceptance-macos` job closes a publish run
(tebako-runtime-r#6's coverage): per macos arch, the contract-pinned
tebako CLI installs the registry default's pair into a scratch
`TEBAKO_HOME` and `tools/boot_smoke --scenario published-pair` executes
it — the build-tree smoke cannot see the installed flow. The release
shard (`.manifest.json`), the `.sha256` sidecars, the era-2
`.contract.yaml` card (the gem's required provenance sidecar), and the
blksum sidecar are emitted in-leg by construction; the signing lanes
(below) re-anchor the wrapper's sidecar + shard from the SIGNED bytes
in-leg, so the publish ships sign-then-hash by construction.

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
  computes the wrapper's `.sha256` sidecar + the in-leg release shard's
  digest INSIDE `tools/build_runtime`, so the verify step RE-ANCHORS
  both from the signed bytes before the boot smoke and the upload —
  the leg's build evidence stays byte-truthful, and the publish job's
  gem renders its SERVED shard/sidecars off these same bytes. The
  shard's recorded filename is checked against the contract name — a
  stem-computation drift fails closed.

## The macOS signing arm (spec 31 §5/§8.4)

The php factory's lane, mirrored at this factory's repack scope, in-leg
between the build and the boot smoke — so the smoke exercises the exact
SIGNED bytes (the script leaves the exe quarantine-marked: the boot runs
under Gatekeeper's download path) and the publish anchors them too
(sign-then-hash, spec 34 §1.3). Both macos legs arm
(`matrix.os == 'macos'`).

- **Sign target**: exactly ONE Mach-O — the wrapper exe (`<stem>`, no
  suffix). The .NET SDK lives INSIDE the `.tfs` env image, so no loose
  dylib rides the release tier; the in-image binaries are Microsoft's
  own signed bytes, mounted never extracted.
- **The gate**: the repo variable `APPLE_SIGNING_ENABLED=true` arms;
  anything else ships unsigned BY DESIGN (spec 00 invariant 7 — a loud
  notice, exit 0). Armed + an unresolved `APPLE_*` secret is a fast
  named failure before any signing call — never a partial release.
- **The chain** (`ci/macos-sign-notarize-runtime.sh`): a throwaway
  keychain + the Developer ID Application identity (by cert SHA-1,
  never by name) → `codesign --options runtime --timestamp` with
  `ci/runtime.entitlements` → the notarytool submit (`--wait`) against
  the App Store Connect key → the online-ticket poll
  (`codesign --check-notarization`; the ticket service lags the
  submission status by minutes — the ruby factory's bounded-retry
  lesson) → the quarantine mark. Bare Mach-O keeps an online ticket:
  stapling is unsupported and `spctl` rejects bare CLI tools by design,
  so the documented verification is codesign's notarization check.
- **The entitlement pair** (`ci/runtime.entitlements`):
  `disable-library-validation` (the driver materializes in-image native
  objects — the preload shim — to the host for dlopen/injection; a
  hardened process refuses unsigned dylibs without the grant) +
  `allow-jit` (a grant, never a requirement — CoreCLR's JIT runs in the
  exec'd muxer under Microsoft's own signature). NO
  `allow-dyld-environment-variables` — DELIBERATELY absent: the
  dyld-stripping plane does not reach the exec-cache shape (the shape
  decision above, tebako#1117's verdict). The script asserts the
  embedded profile STATICALLY — the `<true/>` count AND each key by
  name — because no CI runner can police a missing or swapped grant at
  exec time (the tebako-runtime-r#5 class: macOS 15's dyld tolerates
  the omission and serves the shim anyway).
- **The re-anchor**: the lane's mirror of the windows verify step —
  the wrapper's `.sha256` sidecar + the in-leg shard re-hash from the
  signed bytes, before the boot smoke and the upload (armed legs only;
  a gate-off leg's bytes never changed).

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

The install scenarios live beside the per-leg set but never ride a
build leg (they drive the REAL install machinery, not the freshly
built pair): `published-pair` — the publish coordinator's acceptance
(tebako-runtime-r#6's shape). Through the contract-pinned tebako CLI
(`--tebako`) and into a scratch `TEBAKO_HOME`: `add-registry` (this
factory's live registry — `--registry` overrides), `install dotnet`
(the registry default), the shim materializes, `dotnet --info` answers
through it (the SDK band the fixture targets is DISCOVERED from the
answer, never assumed), the hello/console fixture compiles +
`dotnet run`s through the shim (MSBuild + Roslyn + the offline
framework resolution, installed shape), and the app's own RID must
name the host's architecture (the emulation tripwire).

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
- The SDK version grammar:
  `build/lib/tebako_dotnet_builder/pins.rb`
  (`SDK_LINE_GRAMMAR_SOURCE` — the contract schema mirrors it; the
  tebako-release gem's package-name parse flows it through
  `scripts/release_adapter.rb`).
- The package-name grammar's language segment (`tebako#716`, always
  "dotnet"): `Builder::LANG_SEGMENT` — the build stem and the release
  adapter read the one constant.
- The release machinery pin: `contract.yml release_tooling` (the
  Gemfile flows it; tamatebako/tebako-release-tooling is the
  machinery's single owner — `scripts/release_adapter.rb` declares
  this factory's identity through the gem's adapter seam, never a
  copy of the machinery).
- The runtime registry: `tpkg-registry.yaml`, owned by
  `tools/registry_update.rb` (rendered off the release's own shards;
  landed on main by bot PR — never hand-edited beyond
  `status: withdrawn` marks).
- The prune policy: `build/lib/tebako_dotnet_builder/image_builder.rb`.
- The boot-contract scenarios + the compute-floor ceilings:
  `tools/boot_smoke`.
- This architecture: `docs/build-chain.md`.
