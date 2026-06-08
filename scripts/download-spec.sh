#!/usr/bin/env bash
#
# download-spec.sh — download, vendor and pin the plexsphere OpenAPI spec.
#
# Fetches $SPEC_URL into $SPEC_FILE, computes its SHA-256 (cross-platform),
# reads info.version out of the spec, and writes $SPEC_LOCK pinning the spec for
# reproducible generation. Re-running against an unchanged spec produces a
# byte-identical lock, so CI can assert that `make download-spec` leaves no diff
# (see README §"Versioning & reproducibility").
#
# Invoked by `make download-spec`.
set -euo pipefail

SPEC_URL="${SPEC_URL:?SPEC_URL must be set}"
SPEC_FILE="${SPEC_FILE:-spec/plexsphere-v1.yaml}"
SPEC_LOCK="${SPEC_LOCK:-spec/spec-lock.json}"

mkdir -p "$(dirname "$SPEC_FILE")"

echo ">> Downloading spec from ${SPEC_URL}"
curl -fsSL "$SPEC_URL" -o "$SPEC_FILE"

# Optional: inject a `servers` block here. Deliberately left disabled — the spec
# omits `servers` because the host is environment-dependent (dev/staging/prod/
# on-prem), so callers set the base URL at runtime. Only enable this if a
# sensible default URL actually exists, otherwise it is misleading. See README
# §"No servers block".
#
#   yq -i '.servers = [{"url": "https://api.plexsphere.com"}]' "$SPEC_FILE"

# SHA-256, cross-platform (Linux coreutils vs. macOS/BSD).
if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$SPEC_FILE" | awk '{print $1}')"
else
  SHA="$(shasum -a 256 "$SPEC_FILE" | awk '{print $1}')"
fi

# Pull the API version from the spec (info.version); fall back to "unknown".
API_VERSION="$(grep -m1 -E '^  version:' "$SPEC_FILE" | sed -E 's/.*version:[[:space:]]*//' | tr -d '"' || true)"
API_VERSION="${API_VERSION:-unknown}"

# Reuse the previous fetchedAt when the spec is byte-identical, so the lock stays
# stable across re-runs; only stamp a new time when the spec actually changed.
prev_lock_field() {
  # Read a string field from our own fixed-format lock JSON (keeps jq optional).
  local key="$1"
  [ -f "$SPEC_LOCK" ] || return 0
  sed -n -E "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$SPEC_LOCK" | head -n1
}

PREV_SHA="$(prev_lock_field sha256 || true)"
PREV_FETCHED_AT="$(prev_lock_field fetchedAt || true)"
if [ -n "$PREV_FETCHED_AT" ] && [ "$SHA" = "$PREV_SHA" ]; then
  FETCHED_AT="$PREV_FETCHED_AT"
else
  FETCHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

cat > "$SPEC_LOCK" <<EOF
{
  "source": "${SPEC_URL}",
  "file": "${SPEC_FILE}",
  "apiVersion": "${API_VERSION}",
  "sha256": "${SHA}",
  "fetchedAt": "${FETCHED_AT}"
}
EOF

echo ">> Saved:  ${SPEC_FILE}"
echo ">> Lock:   ${SPEC_LOCK} (sha256=${SHA:0:12}…, apiVersion=${API_VERSION})"
