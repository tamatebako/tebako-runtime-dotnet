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

## Repo status: pre-release skeleton

One leg (linux-gnu x86_64) green: `tools/build_runtime` (the repack
flow — fetch/verify → stage/prune → image → pair → sidecars →
read-back → extracted smoke) + `tools/boot_smoke` (the contract
scenarios), wired into `build-linux-gnu.yml` (a thin trigger over
`_build-platform.yml`: parity → compute → build → verify) plus the
static gate (`lint.yml`). **No release has been cut** — the first
release is the owner's explicit act (README's follow-ups name the
remaining increments: the other triplets, publish+sign+registry, the
monitor, the preload re-evaluation, the web workload, the payload
lane).

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
- Local container builds need docker with the linux/amd64 platform
  (`docker run --platform linux/amd64` on arm64 hosts). The leg needs
  `ruby curl tar libicu74 libssl3` inside the container (the .NET
  muxer's own deps).
- The exec-cache first boot materializes the pruned SDK tree (~0.5 GB)
  once per TMPDIR — keep TMPDIR stable across local smoke runs (the
  boot smoke does).
- `gh pr create` bodies: always `--body-file` — inline `--body` with
  backticks executes them (ecosystem §13).
- Architecture/chain questions: `docs/build-chain.md` first, then
  README.md. If you change a workflow, the build tooling, the matrix,
  the prune policy, or a cache key, update `docs/build-chain.md` in the
  same PR.
