#!/usr/bin/env bash
# Produces the Python SDK. Requirements: Java, Python (black/isort optional).
generate_sdk() {
  local JAR="$1" SPEC="$2" OUT="$3"
  local CONFIG="languages/python/openapi-generator-config.yaml"

  java -jar "$JAR" generate \
    -i "$SPEC" \
    -g python \
    -o "$OUT" \
    -c "$CONFIG" \
    --package-name plexsphere \
    --http-user-agent "plexsphere-sdk-python"

  rm -rf "$OUT/.openapi-generator"
  if command -v black >/dev/null 2>&1; then black "$OUT/plexsphere" || true; fi
  if command -v isort >/dev/null 2>&1; then isort "$OUT/plexsphere" || true; fi
}
