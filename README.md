# tebako-runtime-dotnet

Builds the prebuilt tebako .NET runtime pairs
(`tebako-runtime-<tebako-line>-dotnet-<sdk-version>-<triplet>[.exe]` +
the env `.tfs` image) that the tebako bootstrap/shim resolves at
press/run time. A **repack** factory (the
[tebako-runtime-openjdk](https://github.com/tamatebako/tebako-runtime-openjdk)
/ [tebako-runtime-node](https://github.com/tamatebako/tebako-runtime-node)
grammar): Microsoft ships compiled per-RID .NET SDK builds — this
factory downloads them sha256-pinned, prunes the SDK tree to the
declared scope, and images it. Nothing compiles here. The repo
conventions follow
[tebako-runtime-php](https://github.com/tamatebako/tebako-runtime-php)
(contract.yml + versions.yml SSOT, the contract gate, the staged
workflow).

**Status: pre-release.** Six legs — linux-gnu x86_64, linux-musl
x86_64, macOS arm64 + x86_64, windows ucrt x64 + arm64 — build the
runtime pair and pass the boot smoke (`dotnet --info` answers off the
pair; a hand-written console fixture compiles with `dotnet run` inside
the pair and executes; the compute-floor probe times fib(35) inside the
runtime; the driver-contract error pins hold). The chain — fetch/verify
→ stage/prune → image → pair → sidecars → read-back → boot smoke — is
implemented in `build/lib/tebako_dotnet_builder/` +
`tools/build_runtime` + `tools/boot_smoke` and wired into four thin
triggers (`build-linux-gnu.yml`, `build-linux-musl.yml`,
`build-macos.yml`, `build-windows.yml`) over `_build-platform.yml`
(parity → compute → preflight → build → verify). **No release has been
cut**: every increment stays draft-PR-only until the whole chain is
green end-to-end (the owner's rule).

What is missing, each its own increment (see Follow-ups): the publish
pipeline + signing + registry render, the Microsoft release monitor,
the preload-visibility re-evaluation, and the ASP.NET/web workload.

## The driver link: the spec-29 wrapper, not a relink, not a custom host

.NET ships as Microsoft's compiled bytes; the spec-17 driver cannot be
linked into bytes tebako did not compile. The runtime pair's exe
artifact is therefore the **tebako-runtime-launcher** (the spec-29
wrapper — the tebako-owned process entry point with the driver
embedded), consumed sha256-verified from the pinned tamatebako/tebako
release, exactly like openjdk/node/bun. The env image carries the real
interpreter (the `dotnet` muxer) at its root and declares it under
`layout.interpreter`.

The considered alternative — a custom apphost embedding the runtime via
Microsoft's `hostfxr` hosting API with the driver linked into THAT —
was rejected for the runtime pair: it authors new native code in the
ecosystem (the "the product is Rust" law; the factories' only native
TUs are the proven fs-TU pattern of the source-build factories), and it
replaces the dotnet **muxer**, whose SDK-resolution surface
(`--info`, `global.json` band resolution, the SDK verbs) a custom
apphost would have to reimplement. Chaining a custom apphost to the
real muxer is the wrapper with extra steps. `hostfxr` hosting stays the
right answer for a future *app-payload-side* single-exe embedding
story — a named candidate for the payload increments, never for the
runtime pair.

## Visibility: exec-cache

The env image declares `visibility: "exec-cache"` (spec 29 §3's tier
2b) with the `home: "/"` annotation: at boot the wrapper materializes
the whole SDK tree into the content-addressed exec cache and spawns the
host-real muxer. The evidence for choosing it over the preload tier:

- The `dotnet` muxer **self-locates its home** — `host/fxr`, the `sdk/`
  feature bands, the `shared/` frameworks — from its own exe path, and
  loads `libhostfxr` → `libcoreclr` → `libclrjit` via `dlopen` from
  that tree. Under exec-cache the tree is host-real, so self-location
  and the dlopen closure work with zero interposition risk. This is the
  openjdk precedent verbatim ("a JVM needs no VFS once its home is
  materialized"; the java launcher self-locates `libjvm` the same way).
- Under preload, the wrapper materializes only the interpreter exe's
  load closure and arms `LD_PRELOAD` — the muxer's own-path discovery
  and its dlopen'd hostfxr/coreclr closure would ride the shim, the
  unproven path for this host model. node proves preload for an
  interpreter whose home is *not* self-located from its exe path; that
  evidence does not transfer to the muxer.
- Cost, recorded honestly: the first boot per image content copies the
  pruned SDK tree (~0.5 GB) into the exec cache; later boots reuse the
  content-keyed cache. exec-cache is also the only windows mechanism,
  so the declaration is uniform across every future leg.

The preload tier is the named future refinement (Follow-ups) — a
re-evaluation with measurements, if first-boot cost becomes the pain.

## The prune policy (the skeleton's declared scope)

The env image carries the SDK tree pruned to the **console/classlib
build+run toolchain**:

- **Kept** (asserted present at build time): the `dotnet` muxer,
  `host/fxr/`, `shared/Microsoft.NETCore.App/` (the shared runtime),
  `packs/Microsoft.NETCore.App.Ref` + `packs/Microsoft.NETCore.App.Host.<rid>`
  (the bundled targeting + apphost packs — offline compile of
  `net10.0` apps), `sdk/<band>/` whole (MSBuild, Roslyn, NuGet, F# —
  the SDK is the SDK), `sdk-manifests/`, `templates/`, and the license
  carriage (`LICENSE.txt`, `ThirdPartyNotices.txt`).
- **Pruned** (asserted absent; re-addable by recipe edit when their
  increment lands): `shared/Microsoft.AspNetCore.App` +
  `packs/Microsoft.AspNetCore.App.Ref` (the web workload is its own
  increment), `sdk/<band>/TestHostNetFramework` (vstest's .NET
  Framework test host — the windows-only legacy line, dead bytes on
  every tebako target).

An SDK bump whose tree shape drifted fails the build by name
(`build/lib/tebako_dotnet_builder/image_builder.rb`), never a silent
scope change.

## The artifacts (per version × triplet)

- `tebako-runtime-<line>-dotnet-<sdk>-<platform>[.exe]` — the wrapper
  exe (0755): the spec-29 process entry point from the pinned product
  release.
- `tebako-runtime-<line>-dotnet-<sdk>-<platform>.tfs` — the env image
  (limnifs): the pruned SDK tree + `/lib/tebako/layout.yaml` (era 2,
  `interpreter: /dotnet`, `visibility: exec-cache`, the POSIX
  `preload_shim` grant) + `lib/tebako/libtfs_preload.so` (POSIX — the
  jail's host-IO binding survives the exec) + `/__tpkg__/manifest.yaml`
  (the tier-1 runtime manifest: kind runtime, engine dotnet, the
  `home: "/"` annotation).
- `<stem>.tfs.blksum.json` — the lazy-mount digest sidecar (spec 39 §3).
- Per-asset `.sha256` sidecars (the store's trust-anchor shape) and the
  `<stem>.manifest.json` release shard (spec 13 §2a's write-once
  per-leg metadata unit — consumed by the publish increment).

The `<line>` segment is the tebako product line the pair builds against
(`2.8.83` at pin time — the openjdk grammar: the release tag IS the
tebako line). The registry version (when the publish increment lands)
is the plain SDK version (`10.0.404`).

## The flow

```
builds.dotnet.microsoft.com        tamatebako/tebako release
dotnet-sdk-<v>-<rid>.tar.gz        tebako-runtime-launcher-<line>-<pid>
(sha256-pinned in versions.yml,    tfs-<line>-<pid>
 cross-checked vs Microsoft's      link-unit-<line>-<pid>.tar.gz
 published sha512)                 (sha256-pinned in contract.yml)
        |                                   |
        v                                   v
   fetch + verify  ──────────────►  stage + prune the SDK tree
        (console/classlib scope — the documented policy)
                        |
                        v
        embed /__tpkg__/manifest.yaml + /lib/tebako/layout.yaml
        (+ lib/tebako/libtfs_preload.so on POSIX)
        pack <stem>.tfs  (tfs mkimage — limnifs, the product default)
                        |
                        v
        pair with the wrapper exe -> .sha256 sidecars
        + the .manifest.json shard + the blksum sidecar
                        |
                        v
        read-back (manifest validates, layout/entrypoint present,
        prune policy held) -> extracted-tree smoke (dotnet --info
        names the pinned SDK + runtime) -> tools/boot_smoke
        (bare/boot/compile/dll/compute-floor/bad-mount/mount-root
        scenarios)
```

## The boot smoke (tools/boot_smoke)

Every leg runs the same scenario set — bare, boot, compile, dll,
**compute-floor**, and the named-error trio (bad-mount → 69,
mount-root-malformed → 65, override-ungranted → 78). The compute-floor
(tebako-runtime-python#79's lesson: a leg that computes at a fraction of
the matrix's rate ships green under a boot-only gate) compiles a small
C# probe inside the pair and times a fixed recursive fib(35) loop with
`Stopwatch` inside the process — best of three, so boot/mount cost and
scheduling noise never enter the measurement — against a per-platform
ceiling (a regression tripwire, never a benchmark). The probe also
reports `RuntimeInformation.ProcessArchitecture`: the repack's
slow-compute class is a pair transplanted under emulation, and the
process architecture must be the leg's own. Mode is `COMPUTE_FLOOR_MODE`:
`fail` everywhere except the macos-x86_64 leg, which rides `warn` —
the live tebako#1095 slow-compute defect on real Intel silicon is the
product repo's to fix (the php factory's carve-out; **removal
condition**: delete the warn arm when tebako#1095 closes).

On the windows legs every boot additionally runs with PATH scrubbed to
the Windows system directories (the audience-rule condition — a bare
windows machine carries no mingw/msys toolchain), and the CLI/exec-cache
roots ride the smoke's scratch via USERPROFILE/TMP/TEMP. The PE/ucrt
materialize path is the boot under test: exec-cache materializes the
image's tree host-real and the muxer + hostfxr + coreclr load from it.

## Matrix grammar

The env vocabulary lives in `.github/matrix.json`; the version catalog
lives in `contract.yml` (the SSOT) and the source pins in
`versions.yml` — versions, tags, and SHAs never appear in workflow
YAML. The dispatch filters are `dotnet_filter=full|tidy|catalog|<list>`,
`platform=all|linux-gnu|linux-musl|macos|windows`,
`arch_filter=all|x86_64|arm64` — the php factory's grammar, so the next
platform's increment adds a matrix row, never a re-derivation. The six
rows today:

| os | arch | host | shape |
|----|------|------|-------|
| linux-gnu | x86_64 | ubuntu-24.04 | runner-native (the image carries ruby + libicu74 + libssl3) |
| linux-musl | x86_64 | ubuntu-24.04 | the container-leg idiom: build + smokes docker-run inside the digest-pinned `tpkg-builder-x86_64-linux-musl` image (the pinned musl binaries execute only under musl libc), `apk add icu` in-leg — the gnu runner's preinstalled libicu74's musl mirror |
| macos | arm64 | macos-15 | runner-native + an explicit setup-ruby (the system ruby predates the tooling's floor) |
| macos | x86_64 | macos-15-intel | the same, on real Intel silicon; the compute-floor rides `warn` here ALONE (the live tebako#1095 slow-compute defect — see the boot smoke section) |
| windows | x86_64 | windows-latest | runner-native on the openjdk ucrt idiom: msys2 ucrt64 supplies bsdtar (GNU tar cannot read the `.zip` SDK archive); the build step runs a closed PATH |
| windows | arm64 | windows-11-arm | runner-native, no msys2 — the in-box `C:\Windows\System32\tar.exe` reads the zip |

There is **no macOS deployment-floor env** in this factory: the floor is
a compile-time concern (clang stamps `LC_BUILD_VERSION` per invocation,
so the php/ruby factories ride `MACOSX_DEPLOYMENT_TARGET` through their
whole build) and a repack compiles nothing — the wrapper exe and the tfs
CLI carry the product repo's floor, Microsoft's binaries carry
Microsoft's.

## contract.yml — the pins

- `contract_version: 2` — the bootstrap ↔ runtime contract (spec 17
  grammar). Floored at 2 by the schema: no contract-1 era exists here.
- `link_unit_release: "v2.8.83"` — the tamatebako/tebako release whose
  wrapper exe / tfs CLI / link-unit tarball the legs consume.
- `tools.sha256` — the per-platform digests for those downloads (the
  wrapper/tfs pins cross-checked against the release's own SHA256SUMS
  at fetch time; the link-unit pin is its single anchor). Only the
  leg'd platforms carry pins — a pin no leg consumes is config debt.
- `container_version` + `container_digests` — the musl leg's
  tpkg-builder container line: the moving family tag plus the immutable
  ghcr manifest digest per (container × arch), proved live == recorded
  by the preflight job before any leg spends compute (the ruby#381
  idiom — a retagged toolchain container under an unchanged tag fails
  the run before the legs start).
- `dotnet:` — the version catalog (`catalog` / `full` / `tidy` sets).
  The per-version, per-triplet **source pins** (url + sha256 +
  Microsoft's sha512) live in `versions.yml`;
  `scripts/check_contract.rb` cross-locks the two and proves every
  matrix leg's triplet is pinned.

## Layout

- `contract.yml` + `schema/` — the pins and the version catalog, and
  their JSON Schema; `scripts/check_contract.rb` validates (CI),
  including the driver-source parity arm (contract.yml ↔ the consumed
  driver's compiled-in contract version at the pinned release).
- `versions.yml` — the .NET SDK source pins (url + sha256 +
  upstream_sha512 per triplet, with the honest availability note).
- `scripts/versions` — emits the catalog / resolves the dispatch filter
  grammar / reads the pins (contract.yml is the SSOT).
- `scripts/compute_matrix.rb` — the matrix engine: catalog × env
  vocabulary under the dispatch filters → the leg matrix.
- `tools/build_runtime` — the build entry point (fetch → verify →
  stage/prune → image → pair → sidecars → read-back → extracted smoke).
- `tools/boot_smoke` — the post-build acceptance gate (bare/boot/
  compile/dll/compute-floor/bad-mount/mount-root-malformed/
  override-ungranted).
- `build/lib/tebako_dotnet_builder/` — the build model (Contract, Pins,
  Platform, Fetcher, Toolchain, ImageBuilder, Builder).
- `manifests/` — the tier-1 runtime manifest + the layout declaration
  templates the build renders into the image.
- `.github/workflows/_build-platform.yml` — the one per-platform
  workflow (parity → compute → preflight → build → verify), called by
  the thin triggers (`build-linux-gnu.yml`, `build-linux-musl.yml`,
  `build-macos.yml`, `build-windows.yml`).
- `.github/workflows/lint.yml` — the static gate: schema validation,
  catalog/matrix resolution, the `ruby -c` sweep, YAML/JSON parse
  checks.
- `docs/build-chain.md` — the normative architecture + invariants.

## Local build

`tools/build_runtime` runs anywhere Ruby + curl + tar exist for the
leg's own platform. The macOS legs build natively on a mac of the
matching arch (an arm64 mac also runs the x86_64 leg under Rosetta).
The linux legs run in docker on non-linux hosts (the host's
linux/amd64 platform — e.g. `docker run --platform linux/amd64` on
arm64 macs); the musl leg rides the same digest-pinned container CI
uses:

```sh
# linux-gnu (the gnu runner's local mirror — ubuntu carries the muxer's deps)
docker run --rm --platform linux/amd64 \
  -v "$PWD:/work" -w /work ubuntu:24.04 bash -c '
    apt-get update -qq && apt-get install -y -qq ruby curl ca-certificates tar libicu74 libssl3 >/dev/null
    tools/build_runtime --dotnet 10.0.404 --triplet x86_64-linux-gnu
    TEBAKO_RUNTIME_ROOT=runtime-packages tools/boot_smoke'

# linux-musl (the pinned CI container + the in-leg icu install)
docker run --rm --platform linux/amd64 \
  -v "$PWD:/mnt/w" -w /mnt/w \
  ghcr.io/tamatebako/tpkg-builder-x86_64-linux-musl:v1@sha256:e933e07cc7320b53fd558a3ede20728530bb0b1fbcf8100efc55f5ac80b97e2d \
  bash -c '
    apk add --no-cache icu
    tools/build_runtime --dotnet 10.0.404 --triplet x86_64-linux-musl
    TEBAKO_RUNTIME_ROOT=runtime-packages tools/boot_smoke'
```

(The digest above is illustrative — read the live pin from
`contract.yml container_digests`; the container runs as root, so `chown`
the `.build/` + `runtime-packages/` trees back to your user afterwards,
the workflow's grammar.)

## Follow-ups

1. The publish pipeline (per-leg publish+sign via the tebako-release
   gem, the audit, the registry render + bot PR) and the first release
   — the owner's explicit act, never the agent's. This is the next
   increment; the legs already emit every byte it consumes (the pair,
   the sidecars, the release shard).
2. The Microsoft release monitor (the releases-index watch + pin-bump
   PRs).
3. The preload-visibility re-evaluation (measurements first; the
   exec-cache first-boot cost is recorded above).
4. The ASP.NET/web workload increment (re-adds the pruned packs).
5. The payload lane: app payloads pressed against this runtime
   (single-file/framework-dependent dll delivery through the driver's
   entry materialization — pinned by evidence in that increment), and
   the hostfxr custom-apphost evaluation for app-side single-exe
   embedding.
6. linux-arm64 / linux-musl-arm64 legs: Microsoft ships those SDK
   builds, but no leg demands them yet — their increment records the
   pins and adds the matrix rows (the arm64 linux containers exist
   beside the x86_64 one).
7. The boot-contract parity `spec/` suite against the driver's contract
   suite where the cases overlap.
