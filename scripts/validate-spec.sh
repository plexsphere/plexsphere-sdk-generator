#!/usr/bin/env bash
#
# validate-spec.sh — validate the vendored plexsphere OpenAPI spec.
#
# Makes the pinned OpenAPI Generator jar available (via scripts/_fetch_jar.sh)
# and runs `openapi-generator validate --recommend` against $SPEC_FILE. The
# generator is the only tool required; no extra linter is needed.
#
# Invoked by `make validate-spec`.
set -euo pipefail

SPEC_FILE="${SPEC_FILE:-spec/plexsphere-v1.yaml}"
GENERATOR_VERSION="${GENERATOR_VERSION:?GENERATOR_VERSION must be set (>=7.x for OpenAPI 3.1)}"

# Anchor to the repo root so the relative bin/ and spec/ paths resolve no matter
# where the script is invoked from.
ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

command -v java >/dev/null 2>&1 || { echo "! Java not installed (OpenAPI Generator needs a JRE)." >&2; exit 1; }
[ -f "$SPEC_FILE" ] || { echo "! Spec ${SPEC_FILE} missing. Run 'make download-spec' first." >&2; exit 1; }

# shellcheck source=scripts/_fetch_jar.sh
source scripts/_fetch_jar.sh
JAR="$(fetch_jar "$GENERATOR_VERSION")"

echo ">> Validating ${SPEC_FILE}"
java -jar "$JAR" validate --recommend -i "$SPEC_FILE"
