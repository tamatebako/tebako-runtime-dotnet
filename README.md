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

**Status: pre-release skeleton.** One leg — linux-gnu x86_64 — builds
the runtime pair and passes the boot smoke (`dotnet --info` answers off
the pair; a hand-written console fixture compiles with `dotnet run`
inside the pair and executes; the driver-contract error pins hold). The
chain — fetch/verify → stage/prune → image → pair → sidecars →
read-back → boot smoke — is implemented in `build/lib/tebako_dotnet_builder/`
+ `tools/build_runtime` + `tools/boot_smoke` and wired into
`build-linux-gnu.yml` (a thin trigger over `_build-platform.yml`). **No
release has been cut**: every increment stays draft-PR-only until the
whole chain is green end-to-end (the owner's rule).

What is missing, each its own increment (see Follow-ups): the other
triplets (their SDK pins are already recorded in `versions.yml`), the
publish pipeline + signing + registry render, the Microsoft release
monitor, the preload-visibility re-evaluation, and the ASP.NET/web
workload.

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
        (bare/boot/compile/dll/bad-mount/mount-root scenarios)
```

## Matrix grammar

The env vocabulary lives in `.github/matrix.json` (one row today:
linux-gnu x86_64 on ubuntu-24.04, runner-native — a repack needs no
toolchain container); the version catalog lives in `contract.yml` (the
SSOT) and the source pins in `versions.yml` — versions, tags, and SHAs
never appear in workflow YAML. The dispatch filters are
`dotnet_filter=full|tidy|catalog|<list>`, `platform=all|linux-gnu|…`,
`arch_filter=all|x86_64|arm64` — the php factory's grammar, so the next
platform's increment adds a matrix row, never a re-derivation.

## contract.yml — the pins

- `contract_version: 2` — the bootstrap ↔ runtime contract (spec 17
  grammar). Floored at 2 by the schema: no contract-1 era exists here.
- `link_unit_release: "v2.8.83"` — the tamatebako/tebako release whose
  wrapper exe / tfs CLI / link-unit tarball the legs consume.
- `tools.sha256` — the per-platform digests for those downloads (the
  wrapper/tfs pins cross-checked against the release's own SHA256SUMS
  at fetch time; the link-unit pin is its single anchor). Only the
  leg'd platforms carry pins — a pin no leg consumes is config debt.
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
  compile/dll/bad-mount/mount-root-malformed/override-ungranted).
- `build/lib/tebako_dotnet_builder/` — the build model (Contract, Pins,
  Platform, Fetcher, Toolchain, ImageBuilder, Builder).
- `manifests/` — the tier-1 runtime manifest + the layout declaration
  templates the build renders into the image.
- `.github/workflows/_build-platform.yml` — the one per-platform
  workflow (parity → compute → build → verify), called by the thin
  trigger `build-linux-gnu.yml`.
- `.github/workflows/lint.yml` — the static gate: schema validation,
  catalog/matrix resolution, the `ruby -c` sweep, YAML/JSON parse
  checks.
- `docs/build-chain.md` — the normative architecture + invariants.

## Local build

`tools/build_runtime` runs anywhere Ruby + curl + tar exist for the
leg's own platform. On non-linux hosts the linux leg runs in docker
(the host's linux/amd64 platform — e.g. `docker run --platform
linux/amd64` on arm64 macs):

```sh
docker run --rm --platform linux/amd64 \
  -v "$PWD:/work" -w /work ubuntu:24.04 bash -c '
    apt-get update -qq && apt-get install -y -qq ruby curl ca-certificates tar libicu74 libssl3 >/dev/null
    tools/build_runtime --dotnet 10.0.404 --triplet x86_64-linux-gnu
    TEBAKO_RUNTIME_ROOT=runtime-packages tools/boot_smoke'
```

## Follow-ups

1. The remaining triplets: linux-musl x86_64, macOS arm64 + x86_64,
   windows ucrt x64 + arm64 (their SDK pins are already recorded in
   `versions.yml`; each increment adds its matrix row, its toolchain
   pins in `contract.yml`, and its thin `build-<platform>.yml` trigger).
   linux-arm64 / linux-musl-arm64 SDK builds exist upstream but are
   unpinned — no leg demands them yet.
2. The publish pipeline (per-leg publish+sign via the tebako-release
   gem, the audit, the registry render + bot PR) and the first release
   — the owner's explicit act, never the agent's.
3. The Microsoft release monitor (the releases-index watch + pin-bump
   PRs).
4. The preload-visibility re-evaluation (measurements first; the
   exec-cache first-boot cost is recorded above).
5. The ASP.NET/web workload increment (re-adds the pruned packs).
6. The payload lane: app payloads pressed against this runtime
   (single-file/framework-dependent dll delivery through the driver's
   entry materialization — pinned by evidence in that increment), and
   the hostfxr custom-apphost evaluation for app-side single-exe
   embedding.
7. The boot-contract parity `spec/` suite against the driver's contract
   suite where the cases overlap.
