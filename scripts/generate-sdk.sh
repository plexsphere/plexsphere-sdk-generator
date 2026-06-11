#!/usr/bin/env bash
#
# generate-sdk.sh — orchestrate OpenAPI SDK generation for one language.
#
# Resolves the repo root, verifies the prerequisites (Java, the vendored spec,
# and a scripts/languages/<lang>.sh handler), makes the pinned OpenAPI Generator
# jar available (via scripts/_fetch_jar.sh), recreates dist/<lang>/ for a clean
# build, then sources the language script and calls its generate_sdk function:
#
#   generate_sdk "$JAR" "$SPEC_FILE" "$OUT_DIR"
#
# This is the single-spec analogue of STACKIT's generate-sdk.sh — same pattern,
# without the multi-service loop (see README §"Step 4").
#
# Invoked by `make generate-<lang>` (e.g. `make generate-go`).
set -euo pipefail

LANGUAGE="${1:?Usage: generate-sdk.sh <language>}"
SPEC_FILE="${SPEC_FILE:-spec/plexsphere-v1.yaml}"
GENERATOR_VERSION="${GENERATOR_VERSION:?GENERATOR_VERSION must be set (>=7.x for OpenAPI 3.1)}"

# Anchor to the repo root so the relative bin/, spec/ and scripts/ paths resolve
# no matter where the script is invoked from.
ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

LANG_SCRIPT="scripts/languages/${LANGUAGE}.sh"

command -v java >/dev/null 2>&1 || { echo "! Java not installed (OpenAPI Generator needs a JRE)." >&2; exit 1; }
[ -f "$SPEC_FILE" ]   || { echo "! Spec ${SPEC_FILE} missing. Run 'make download-spec' first." >&2; exit 1; }
[ -f "$LANG_SCRIPT" ] || { echo "! No support for '${LANGUAGE}' (${LANG_SCRIPT} missing)." >&2; exit 1; }

# Make the pinned generator jar available (shared with validate-spec.sh).
# shellcheck source=scripts/_fetch_jar.sh
source scripts/_fetch_jar.sh
JAR="$(fetch_jar "$GENERATOR_VERSION")"

# Recreate the output directory so each run starts from a clean slate.
OUT_DIR="dist/${LANGUAGE}"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo ">> Generating ${LANGUAGE} SDK into ${OUT_DIR}"
# Load the language-specific generate_sdk function and run it.
# shellcheck source=/dev/null
source "$LANG_SCRIPT"
generate_sdk "$JAR" "$SPEC_FILE" "$OUT_DIR"

# Drop files the SDK repo owns or does not want before the tree is overlaid
# (rsync without --delete) onto the SDK repo. The set is declared in
# languages/<lang>/.openapi-generator-ignore and enforced here, NOT via
# openapi-generator's --ignore-file-override: that flag matches patterns
# relative to the ignore file's own directory, so an out-of-tree override never
# matched and the generator shipped .github/ (rejected without `workflow` scope
# on SDK_PR_TOKEN), README.md and the helper scaffolding regardless.
IGNORE_FILE="languages/${LANGUAGE}/.openapi-generator-ignore"
if [ -f "$IGNORE_FILE" ]; then
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in
      '' | '#'*) continue ;;   # skip blank lines and comments
    esac
    echo ">> Pruning generated ${pattern%/}"
    rm -rf "${OUT_DIR:?}/${pattern%/}"
  done < "$IGNORE_FILE"
fi

echo ">> Done: ${OUT_DIR}"
