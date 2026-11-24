#!/bin/bash
# windows-sign-gate.sh — the spec 34 §4 enablement gate for the Windows
# runtime legs (the python factory's same-named script, ported; itself
# the ruby factory's mirror of tamatebako/tebako PR #566's
# ci/windows-sign-gate.sh). The repo variable WINDOWS_SIGNING_ENABLED=true
# arms Azure Trusted Signing (Authenticode) for the leg's PE artifact —
# the wrapper exe (this repack factory ships exactly ONE host-level PE:
# the .NET SDK lives INSIDE the .tfs env image, so no loose DLL rides
# the release tier); anything else ships unsigned BY DESIGN (spec 00
# invariant 7: unsigned stays first-class) and this step is a loud
# notice. Armed but a secret/variable unresolved is a FAST named failure
# BEFORE any signing call — never a partial release (spec 34 §7.5).
#
# Emits armed=<true|false> to GITHUB_OUTPUT; the leg's PE staging,
# azure/login, artifact-signing and signtool-verify steps all gate on it.
# The re-hash note (spec 34 §1.3 sign-then-hash): this factory's repack
# grammar computes the wrapper's .sha256 sidecar + the release shard's
# digest INSIDE tools/build_runtime (there is no publish-time uploader
# yet — pre-release), so the verify step RE-ANCHORS both from the signed
# bytes before the boot smoke and the upload (see _build-platform.yml).
#
# Required env when armed (spec 34 §3): AZURE_CLIENT_ID, AZURE_TENANT_ID,
# AZURE_SUBSCRIPTION_ID (org secrets — the OIDC identity; no
# AZURE_CLIENT_SECRET exists anywhere), AZURE_ENDPOINT,
# AZURE_SIGNING_ACCOUNT_NAME, AZURE_SIGNING_CERT_PROFILE (org variables).
# Runner env: WINDOWS_SIGNING_ENABLED (from vars.), GITHUB_OUTPUT.
set -euo pipefail

if [ "${WINDOWS_SIGNING_ENABLED:-false}" != "true" ]; then
  echo "::notice::spec 34: WINDOWS_SIGNING_ENABLED != true — this leg ships UNSIGNED (spec 00 invariant 7)"
  echo "armed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

missing=""
for v in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID \
         AZURE_ENDPOINT AZURE_SIGNING_ACCOUNT_NAME AZURE_SIGNING_CERT_PROFILE; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "::error::WINDOWS_SIGNING_ENABLED=true but unset:$missing — spec 34 §7.5: fast failure before any signing call, never a partial release"
  exit 1
fi

echo "armed=true" >> "$GITHUB_OUTPUT"
echo "spec 34: signing armed — Artifact Signing account $AZURE_SIGNING_ACCOUNT_NAME / profile $AZURE_SIGNING_CERT_PROFILE ($AZURE_ENDPOINT)"
