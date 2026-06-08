#!/usr/bin/env bash
#
# _fetch_jar.sh — make the pinned OpenAPI Generator jar available in bin/.
#
# Sourced (not executed) by the scripts that need the generator —
# validate-spec.sh and, later, generate-sdk.sh — so the download lives in one
# place. It provides a single function:
#
#   fetch_jar VERSION
#       Ensure bin/openapi-generator-cli-VERSION.jar exists, downloading it from
#       Maven Central on demand, and print its path on stdout. The download is
#       idempotent: an already-present jar is reused, never re-fetched. Progress
#       goes to stderr so the path can be captured with $(fetch_jar VERSION).
#
# VERSION must be >= 7.x: the plexsphere spec is OpenAPI 3.1 and generators
# before 7.x mishandle it (see README §Prerequisites).

fetch_jar() {
  local version="${1:?fetch_jar: generator version must be set (>=7.x for OpenAPI 3.1)}"

  # Reject generators older than 7.x — they silently mishandle OpenAPI 3.1.
  local major="${version%%.*}"
  if ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt 7 ]; then
    echo "! Unsupported generator version '${version}': need >=7.x for OpenAPI 3.1." >&2
    return 1
  fi

  local jar="bin/openapi-generator-cli-${version}.jar"
  local url="https://repo1.maven.org/maven2/org/openapitools/openapi-generator-cli/${version}/openapi-generator-cli-${version}.jar"

  if [ ! -f "$jar" ]; then
    echo ">> Downloading openapi-generator-cli ${version}" >&2
    mkdir -p bin
    # Remove a partial jar on failure so a later run does not skip a corrupt file.
    curl -fsSL "$url" -o "$jar" || { rm -f "$jar"; return 1; }
  fi

  printf '%s\n' "$jar"
}
