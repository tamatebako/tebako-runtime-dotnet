# AGENTS.md — tebako-runtime-dotnet

The binding rules are the ecosystem's: **tamatebako/AGENTS.md** (the
workspace root) — read it first. The short version as applied here:

- **Draft PRs only.** No merges to `main`, no tags, no releases without
  the owner's explicit go-ahead.
- **Prebuilt artifacts flow downward.** This factory CONSUMES published
  artifacts — Microsoft's per-RID .NET SDK archives (sha256-pinned in
  `versions.yml`, cross-checked against Microsoft's published sha512)
  and the wrapper exe / tfs CLI / link-unit tarball from the pinned
  tamatebako/tebako release (`contract.yml`). Never a source checkout
  of a sibling repo, in CI or locally; never a source build of the
  driver stack or of .NET.
- **SSOT for versions and pins.** Versions, tags, SHAs live in
  `contract.yml` (catalog + toolchain pins), `versions.yml` (source
  url/sha256/sha512 per triplet), and `.github/matrix.json` (env
  vocabulary) — never hardcoded in workflow YAML or scripts.
- **A repack never patches.** The SDK tree ships pristine (extract →
  prune → image); the prune policy lives in
  `build/lib/tebako_dotnet_builder/image_builder.rb` and is documented
  in README.md + docs/build-chain.md. A genuine .NET source need means
  a tamatebako source factory, not a factory-side hot-patch.
- **YAML** for all authored config/manifests; named errors and named
  exit codes, never silent fallbacks.

## Repo status: pre-release

Six legs (linux-gnu x86_64, linux-musl x86_64, macOS arm64 + x86_64,
windows ucrt x64 + arm64): `tools/build_runtime` (the repack flow —
fetch/verify → stage/prune → image → pair → sidecars → read-back →
extracted smoke) + `tools/boot_smoke` (the contract scenarios + the
compute-floor), wired into four thin triggers
(`build-linux-gnu.yml`, `build-linux-musl.yml`, `build-macos.yml`,
`build-windows.yml`) over `_build-platform.yml` (parity → compute →
preflight → build → verify) plus the static gate (`lint.yml`). The
musl leg builds inside the digest-pinned tpkg-builder container (the
preflight proves recorded == live); the macos/windows legs are
runner-native (msys2 ucrt64 bsdtar on windows x64, the in-box
System32 tar.exe on windows arm64). Both windows legs carry the spec 34
§8.2 Azure Trusted Signing lane in-leg (`ci/windows-sign-gate.sh`'s arm
check, OIDC `azure/login` in the `windows-signing` environment, the
RFC 3161 timestamp, and `signtool verify /pa` at the contract path —
behind the `WINDOWS_SIGNING_ENABLED` gate; gate-off ships unsigned
byte-identically, spec 00 invariant 7). The sign target is the wrapper
exe ALONE — the .NET SDK lives inside the env image, so no loose DLL
rides the release tier — and because this factory's repack grammar
computes the `.sha256` sidecar + the release shard's digest inside
`tools/build_runtime` (no publish-time uploader exists yet), the verify
step re-anchors both from the signed bytes (sign-then-hash, spec 34
§1.3; docs/build-chain.md). **No release has been cut** — the first
release is the owner's explicit act (README's follow-ups name the
remaining increments: publish+registry next, then the monitor,
the preload re-evaluation, the web workload, the payload lane).

## Repo-local gotchas

- Tooling is **Ruby** (stdlib-first; gems only via `Gemfile` — today
  only `json_schemer` for the contract gate). Ecosystem §12 rules
  apply: autoload only, no `require_relative`, no
  `send`/`instance_variable_get`/`respond_to?` metaprogramming.
- `Gemfile.lock` is gitignored (factory convention — resolutions float).
- `contract.yml` is validated by `scripts/check_contract.rb` against
  `schema/contract.schema.yml` (`bundle exec`), including the
  driver-source parity arm (contract.yml ↔ the pinned release's
  compiled-in `TEBAKO_CONTRACT_VERSION`) and the matrix-leg coverage
  arm (every `.github/matrix.json` triplet pinned in `versions.yml`).
  A contract bump edits both in the same commit.
- CI containers are `ghcr.io/tamatebako/tpkg-builder-*`
  (tebako-ci-containers) only, pulled `name:tag@digest` (the digest
  lives in `contract.yml container_digests`; the preflight job proves
  it live). The archived v1 `tebako-<platform>` images are never
  referenced here.
- The container legs bind-mount the workspace and run as root —
  root-owned files land in `.build/` and `runtime-packages/`. The
  workflow hands them back to the runner user (`chown` at the end of
  the docker-run step); do the same locally before editing or
  `git clean`-ing.
- Local container builds need docker with the linux/amd64 platform
  (`docker run --platform linux/amd64` on arm64 hosts). The gnu leg's
  ubuntu container needs `ruby curl tar libicu74 libssl3` (the .NET
  muxer's own deps); the musl tpkg-builder container needs `apk add
  icu` in-leg (alpine carries no libicu — the .NET runtime's one
  non-baked host dep).
- The exec-cache first boot materializes the pruned SDK tree (~0.5 GB)
  once per TMPDIR — keep TMPDIR stable across local smoke runs (the
  boot smoke does).
- The windows smoke's PATH is scrubbed to the Windows system
  directories per boot (the audience-rule condition); a debugging boot
  on a windows dev box belongs behind the maintainer's own env, never
  in the smoke.
- `gh pr create` bodies: always `--body-file` — inline `--body` with
  backticks executes them (ecosystem §13).
- Architecture/chain questions: `docs/build-chain.md` first, then
  README.md. If you change a workflow, the build tooling, the matrix,
  the prune policy, or a cache key, update `docs/build-chain.md` in the
  same PR.
