#!/usr/bin/env bash
# Produces the Go SDK. Requirements: Java, Go, goimports.
generate_sdk() {
  local JAR="$1" SPEC="$2" OUT="$3"
  local CONFIG="languages/go/openapi-generator-config.yaml"

  # gofmt as a file post-processor (see openapi-generator file-post-processing)
  export GO_POST_PROCESS_FILE="gofmt -w"

  java -jar "$JAR" generate \
    -i "$SPEC" \
    -g go \
    -o "$OUT" \
    -c "$CONFIG" \
    --package-name plexsphere \
    --git-host github.com \
    --git-user-id plexsphere \
    --git-repo-id plexsphere-sdk-go \
    --http-user-agent "plexsphere-sdk-go" \
    --enable-post-process-file \
    --inline-schema-options "RESOLVE_INLINE_ENUMS=true"

  # Clean up / format
  rm -rf "$OUT/.openapi-generator"
  if command -v goimports >/dev/null 2>&1; then goimports -w "$OUT"; fi
  ( cd "$OUT" && go mod tidy ) || true
}
