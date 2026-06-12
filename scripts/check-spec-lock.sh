#!/usr/bin/env bash
#
# check-spec-lock.sh — assert the vendored spec matches spec/spec-lock.json.
#
# Recomputes the SHA-256 of $SPEC_FILE and compares it to the sha256 pinned in
# $SPEC_LOCK. A mismatch means the vendored spec and its lock have drifted — a
# hand-edited spec without a refreshed lock, or a stale lock — which breaks the
# reproducibility guarantee. The check is offline and deterministic (no network,
# no Java), so it gates every PR without depending on upstream. Keeping the
# vendored spec *current* with upstream is a separate concern handled by
# update-spec.yaml (see README §"Versioning & reproducibility").
#
# Invoked by `make check-spec-lock`.
set -euo pipefail

SPEC_FILE="${SPEC_FILE:-spec/plexsphere-v1.yaml}"
SPEC_LOCK="${SPEC_LOCK:-spec/spec-lock.json}"

# Anchor to the repo root so the relative spec/ paths resolve no matter where
# the script is invoked from.
ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

[ -f "$SPEC_FILE" ] || { echo "! Spec ${SPEC_FILE} missing. Run 'make download-spec' first." >&2; exit 1; }
[ -f "$SPEC_LOCK" ] || { echo "! Lock ${SPEC_LOCK} missing. Run 'make download-spec' first." >&2; exit 1; }

# SHA-256, cross-platform (Linux coreutils vs. macOS/BSD) — same logic as
# download-spec.sh, so the value compared here is the value pinned there.
if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$SPEC_FILE" | awk '{print $1}')"
else
  SHA="$(shasum -a 256 "$SPEC_FILE" | awk '{print $1}')"
fi

# Read sha256 from our own fixed-format lock JSON (keeps jq optional, mirroring
# download-spec.sh's prev_lock_field helper).
LOCK_SHA="$(sed -n -E 's/^[[:space:]]*"sha256"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$SPEC_LOCK" | head -n1)"

[ -n "$LOCK_SHA" ] || { echo "! No sha256 found in ${SPEC_LOCK}." >&2; exit 1; }

if [ "$SHA" != "$LOCK_SHA" ]; then
  {
    echo "! Spec hash does not match the lock:"
    echo "    ${SPEC_FILE}: ${SHA}"
    echo "    ${SPEC_LOCK}: ${LOCK_SHA}"
    echo "  The vendored spec and spec-lock.json have drifted. Run 'make download-spec'"
    echo "  to re-pin the lock, then commit both files."
  } >&2
  exit 1
fi

echo ">> OK: ${SPEC_FILE} matches ${SPEC_LOCK} (sha256=${SHA:0:12}…)"
