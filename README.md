# plexsphere-sdk-generator

Generates SDKs (clients) for the [plexsphere API](https://api.plexsphere.com) in
arbitrary programming languages from the platform's OpenAPI specification.

The actual code generation is done by [OpenAPI Generator](https://openapi-generator.tech).
This repository is the **orchestration and configuration layer** around it: it downloads
the spec, validates it, pins it reproducibly, invokes the generator per language with the
right configuration, and post-processes the result into a publishable SDK.

It is modeled on [`stackitcloud/stackit-sdk-generator`](https://github.com/stackitcloud/stackit-sdk-generator).
We adopt its proven architecture (Makefile + shell orchestration + a pinned generator
version + per-language config/templates + CI PRs) and simplify it where plexsphere has no
multi-service landscape (see [Differences from STACKIT](#differences-from-stackit)).

> **Status:** This repository is still empty. This README *is* the implementation guide —
> it describes step by step *what* to build, *why*, and provides concrete, copy-paste-ready
> file contents to get started.

---

## Table of contents

1. [Goal](#goal)
2. [Background](#background)
3. [How it works (pipeline)](#how-it-works-pipeline)
4. [Prerequisites](#prerequisites)
5. [Repository layout](#repository-layout)
6. [Quickstart](#quickstart)
7. [Implementation, step by step](#implementation-step-by-step)
8. [Plexsphere-specific considerations](#plexsphere-specific-considerations)
9. [Versioning & reproducibility](#versioning--reproducibility)
10. [CI/CD & publishing](#cicd--publishing)
11. [Tests & validation](#tests--validation)
12. [Adding more languages](#adding-more-languages)
13. [Differences from STACKIT](#differences-from-stackit)
14. [References](#references)

---

## Goal

- **One source of truth:** the plexsphere OpenAPI spec
  (`https://api.plexsphere.com/plexsphere-v1.yaml`).
- **Arbitrary languages:** Go, Python, TypeScript, Java, … — a new language is one config
  file plus one small shell script away.
- **Reproducible:** a pinned generator version *and* a pinned spec (by hash), so the exact
  same output can be regenerated at any time.
- **Automatable:** a `make generate-<lang>` locally, the same steps in CI, which on spec
  changes automatically open pull requests against the SDK repositories.

Non-goal: hand-written clients. Everything that can be generated is generated; only
unavoidable additions (e.g. CSRF handling, examples, the SDK's own README) are maintained
as template overrides or "carried-along" files.

---

## Background

### The plexsphere specification

| Property            | Value |
|---------------------|-------|
| OpenAPI version     | **3.1.0** |
| Title / version     | `plexsphere API` / `v1` |
| Source (static)     | `https://api.plexsphere.com/plexsphere-v1.yaml` (loaded by a Redoc view served at `/`) |
| Size                | ~945 KB, **121 paths**, **24 tags** |
| License             | **BUSL-1.1** |
| Error format        | `application/problem+json` (RFC 9457) |
| Auth scheme         | `operatorBearer` (HTTP Bearer, JWT); plus a prose-described cookie+CSRF flow |
| `servers` block     | **deliberately absent** (environment-dependent) |

The tags group the domain functionally, among them: `meta`, `auth`, `admin`, `authz`,
`artifacts`, `labels`, `nodes`, `cloud`, `provisioning-credentials`, `approvals`,
`blueprint`, `resource`, `policy`, `tenancy`, `mesh`, `audit`, `management-fleet`,
`integrity`, `bridge`, `actions`, `access`, `hooks`, `bootstrap-tokens`, `capabilities`.

> **Note:** The host `api.plexsphere.com` currently serves only the docs and the `*.yaml`
> file; the runtime endpoints (`/v1/health`, `/v1/openapi.json`, …) are not deployed there.
> The canonical source for generation is therefore the static `plexsphere-v1.yaml`. (In a
> running deployment the self-describe route `/v1/openapi.json` can serve as an alternative.)

### How STACKIT does it (and what we adopt)

The STACKIT generator consists, at its core, of:

- a **`Makefile`** with targets `project-tools`, `download-oas`, `generate-sdk`,
  `generate-{go,python,java}-sdk`;
- **`scripts/generate-sdk/generate-sdk.sh`** as the orchestrator: checks for Java, picks
  the generator version that matches the language, downloads `openapi-generator-cli.jar`
  from Maven Central (only when needed), and calls the language-specific script;
- **`scripts/generate-sdk/languages/{go,python,java}.sh`**, which run the generator with
  the right flags and post-process the result (e.g. `gofmt`/`goimports`, `go mod tidy`);
- **`languages/<lang>/`** with `openapi-generator-config.yml`, `.openapi-generator-ignore`,
  `blocklist.txt`, and Mustache **`templates/`** for overrides;
- **CI** (`.github/workflows/`) that regenerates on spec updates and opens PRs against the
  SDK repos (Renovate keeps the generator version current).

We adopt this pattern as-is. We drop the **multi-service part** (iterating over many
service specs, `go.work` workspaces, the "compat-layer", `api-versions-lock.json`) because
plexsphere is **a single spec**.

---

## How it works (pipeline)

```
                    plexsphere-v1.yaml  (api.plexsphere.com)
                              │
            make download-spec│   (download + pin sha256 -> spec/spec-lock.json)
                              ▼
                       spec/plexsphere-v1.yaml   (vendored, versioned)
                              │
            make validate-spec│   (openapi-generator validate / optional spectral)
                              ▼
            make generate-<lang>
                              │   scripts/generate-sdk.sh
                              │     ├─ fetch openapi-generator-cli.jar (pinned version)
                              │     └─ scripts/languages/<lang>.sh
                              │           java -jar … generate -g <lang> \
                              │             -i spec/… -o dist/<lang> \
                              │             -c languages/<lang>/openapi-generator-config.yaml
                              ▼
                       dist/<lang>/   (finished SDK + post-processing)
                              │
                    CI / manual│   (commit/PR into the respective SDK repo, publish)
                              ▼
              plexsphere-sdk-go · -python · -typescript · …
```

---

## Prerequisites

| Tool | Purpose | Minimum version |
|------|---------|-----------------|
| **Java (JRE/JDK)** | OpenAPI Generator is a Java tool | 11+ (17 recommended) |
| **bash**, **curl**, **make** | orchestration | current |
| **`yq`** *(optional)* | spec normalization (e.g. inject `servers`), YAML→JSON | v4 |
| **`shasum`/`sha256sum`** | spec pinning | – |
| Go toolchain + `goimports` | Go post-processing only | Go 1.21+ |
| Python + `black`, `isort` | Python post-processing only | 3.9+ |
| Node.js + npm | TypeScript post-processing / optional npm wrapper | 18+ |

> **Important — OpenAPI 3.1:** The plexsphere spec is **3.1.0**. Reliable 3.1 support
> only exists from **OpenAPI Generator 7.x** onward. We therefore pin a 7.x version
> (suggested below: `7.22.0`, as STACKIT currently uses for Go/Python).

The generator is **not** checked into the repo. The orchestrator script downloads the
pinned `openapi-generator-cli-<version>.jar` from Maven Central into `bin/` (gitignored) on
demand. Alternatively the npm wrapper `@openapitools/openapi-generator-cli` with an
`openapitools.json` can be used — see [npm wrapper variant](#variant-npm-wrapper).

---

## Repository layout

This is what the repository should look like once implemented:

```
plexsphere-sdk-generator/
├── README.md                     # this document
├── Makefile                      # entry points: download-spec, validate, generate-*
├── LICENSE                       # license of this generator (not of the SDK)
├── .gitignore
├── openapitools.json             # optional: pins generator version (npm wrapper)
│
├── spec/
│   ├── plexsphere-v1.yaml        # vendored copy of the spec (produced by download-spec)
│   └── spec-lock.json            # source, sha256, fetch time, API version
│
├── bin/                          # (gitignored) downloaded openapi-generator-cli.jar
│
├── scripts/
│   ├── download-spec.sh          # download, verify, pin the spec
│   ├── _fetch_jar.sh             # shared: fetch pinned generator jar into bin/
│   ├── validate-spec.sh          # validate the spec (+ optional lint)
│   ├── generate-sdk.sh           # orchestrator: pick version, fetch jar, dispatch
│   └── languages/
│       ├── go.sh
│       ├── python.sh
│       └── typescript.sh
│
├── languages/
│   ├── go/
│   │   ├── openapi-generator-config.yaml
│   │   ├── .openapi-generator-ignore
│   │   └── templates/            # optional Mustache overrides (e.g. CSRF, UA)
│   ├── python/
│   │   ├── openapi-generator-config.yaml
│   │   ├── .openapi-generator-ignore
│   │   └── templates/
│   └── typescript/
│       ├── openapi-generator-config.yaml
│       └── .openapi-generator-ignore
│
├── dist/                         # (gitignored) generated SDKs land here
│
└── .github/workflows/
    ├── validate.yaml             # PR check: validate spec
    ├── update-spec.yaml          # scheduled: refresh vendored spec, open spec PR
    └── generate.yaml             # on spec change: regenerate SDKs + open PRs
```

---

## Quickstart

After implementing the files described below:

```bash
# 1. Download the current spec and pin it reproducibly
make download-spec

# 2. Validate the spec
make validate-spec

# 3. Generate SDK(s) -> ends up in dist/<lang>/
make generate-go
make generate-python
make generate-typescript

# or all at once
make generate-all
```

---

## Implementation, step by step

The following sections contain **copy-paste-ready** starting versions of every file. Order:
`.gitignore` → `Makefile` → `scripts/*` → `languages/*` → CI. Paths are relative to the repo
root.

### Step 0 — `.gitignore`

```gitignore
/bin/
/dist/
*.class
.DS_Store
```

`spec/` is **committed** (vendored spec + lock); `bin/` and `dist/` are not.

---

### Step 1 — `Makefile`

Thin entry points that delegate to the scripts (analogous to STACKIT). `LANGUAGES` keeps
the supported languages in one place.

```makefile
# Configuration ------------------------------------------------------------
SPEC_URL        ?= https://api.plexsphere.com/plexsphere-v1.yaml
SPEC_FILE       ?= spec/plexsphere-v1.yaml
SPEC_LOCK       ?= spec/spec-lock.json

# Pinned generator version (>=7.x because of OpenAPI 3.1!)
GENERATOR_VERSION ?= 7.22.0

LANGUAGES       := go python typescript

.DEFAULT_GOAL := help

# Targets ------------------------------------------------------------------
.PHONY: help download-spec validate-spec check-spec-lock generate-all $(addprefix generate-,$(LANGUAGES))

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

download-spec: ## Download the OpenAPI spec and pin it (sha256) in spec/spec-lock.json
	@SPEC_URL="$(SPEC_URL)" SPEC_FILE="$(SPEC_FILE)" SPEC_LOCK="$(SPEC_LOCK)" \
	  scripts/download-spec.sh

validate-spec: ## Validate the vendored spec
	@SPEC_FILE="$(SPEC_FILE)" GENERATOR_VERSION="$(GENERATOR_VERSION)" \
	  scripts/validate-spec.sh

check-spec-lock: ## Check the vendored spec matches spec/spec-lock.json (sha256)
	@SPEC_FILE="$(SPEC_FILE)" SPEC_LOCK="$(SPEC_LOCK)" \
	  scripts/check-spec-lock.sh

generate-all: $(addprefix generate-,$(LANGUAGES)) ## Generate all SDKs

generate-%: ## Generate the SDK for <lang> (e.g. make generate-go)
	@SPEC_FILE="$(SPEC_FILE)" GENERATOR_VERSION="$(GENERATOR_VERSION)" \
	  scripts/generate-sdk.sh "$*"
```

---

### Step 2 — `scripts/download-spec.sh`

Downloads the spec into `spec/`, computes the SHA-256, reads `info.version`, and writes a lock
file for reproducibility. Re-running against an unchanged spec preserves `fetchedAt` and
produces a byte-identical lock, so CI can assert that `make download-spec` leaves no diff (see
[Versioning & reproducibility](#versioning--reproducibility)). (Optional: inject a `servers`
block here — see [no `servers` block](#no-servers-block).)

```bash
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
```

`chmod +x scripts/download-spec.sh`.

---

### Step 3 — `scripts/validate-spec.sh` & `scripts/_fetch_jar.sh`

Validation uses the generator itself (no extra tool required). Because the jar download is
shared with the orchestrator (`generate-sdk.sh`, Step 4), it is factored into a small sourced
helper, `scripts/_fetch_jar.sh`, rather than copy-pasted into both callers.

`scripts/_fetch_jar.sh` exposes one function, `fetch_jar VERSION`: it downloads the pinned
`openapi-generator-cli-<version>.jar` from Maven Central into `bin/` (gitignored) on demand —
idempotent, so an already-present jar is reused — and prints its path. It rejects generators
older than 7.x, because the spec is OpenAPI 3.1 (see [Prerequisites](#prerequisites)).

```bash
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
```

`scripts/validate-spec.sh` sources the helper and runs `validate --recommend`. Optionally
[Spectral](https://github.com/stoplightio/spectral) can be hooked in here as well.

```bash
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
```

`chmod +x scripts/validate-spec.sh scripts/_fetch_jar.sh` (the helper is sourced, but the
executable bit is harmless and keeps the scripts uniform).

> **Note — vendored-spec validation status:** under the pinned generator (`7.22.0`),
> `validate` reports one **error** — `attribute info.license.identifier is missing` — because the
> vendored spec deliberately uses a `name`-only license (`spec/plexsphere-v1.yaml`, for
> kin-openapi compatibility) and `validate` exposes no flag to downgrade the check. So
> `make validate-spec` currently exits non-zero on the vendored spec. Whether to add an SPDX
> `identifier` to the spec or to treat this single check as non-fatal is a spec/policy decision,
> separate from this script.

---

### Step 4 — `scripts/generate-sdk.sh` (orchestrator)

Verifies the prerequisites, makes the pinned jar available through the shared
`scripts/_fetch_jar.sh` helper (Step 3), recreates `dist/<lang>/`, and calls the
language-specific script — exactly the pattern from STACKIT's `generate-sdk.sh`, just
without the multi-service loop.

```bash
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

echo ">> Done: ${OUT_DIR}"
```

`chmod +x scripts/generate-sdk.sh`.

---

### Step 5 — Language-specific scripts

Each script defines a function `generate_sdk JAR SPEC OUT`, calls the generator with the
appropriate flags + config, and does the post-processing.

#### `scripts/languages/go.sh`

```bash
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
```

#### `scripts/languages/python.sh`

```bash
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
```

#### `scripts/languages/typescript.sh`

```bash
#!/usr/bin/env bash
# Produces the TypeScript SDK (typescript-fetch). Requirements: Java, Node/npm.
generate_sdk() {
  local JAR="$1" SPEC="$2" OUT="$3"
  local CONFIG="languages/typescript/openapi-generator-config.yaml"

  java -jar "$JAR" generate \
    -i "$SPEC" \
    -g typescript-fetch \
    -o "$OUT" \
    -c "$CONFIG"

  rm -rf "$OUT/.openapi-generator"
  if [ -f "$OUT/package.json" ]; then ( cd "$OUT" && npm install && npm run build ) || true; fi
}
```

`chmod +x scripts/languages/*.sh` (harmless even though they are sourced).

---

### Step 6 — Language configuration & ignore files

The per-language `openapi-generator-config.yaml` bundles all stable options (cleaner than
long CLI flags) and points to an optional `templates/` directory for overrides. List every
option for a generator with `java -jar bin/…jar config-help -g <generator>`.

#### `languages/go/openapi-generator-config.yaml`

```yaml
# Go generator options. Full list: config-help -g go
useOneOfDiscriminatorLookup: true
additionalProperties:
  withGoMod: true                 # generate go.mod too (single-repo SDK)
  isGoSubmodule: false
  enumClassPrefix: true           # prefix enum names with the type -> collision-free
  generateInterfaces: true        # testable API interfaces
  disallowAdditionalPropertiesIfNotPresent: false
  enumUnknownDefaultCase: true    # forward-compatible with new enum values
# Custom Mustache templates (optional, add only when needed):
# templateDir: languages/go/templates
```

#### `languages/python/openapi-generator-config.yaml`

```yaml
# Python generator options. Full list: config-help -g python
additionalProperties:
  packageName: plexsphere
  projectName: plexsphere-sdk
  library: urllib3                # default HTTP backend
  generateSourceCodeOnly: false
  disallowAdditionalPropertiesIfNotPresent: false
# templateDir: languages/python/templates
```

#### `languages/typescript/openapi-generator-config.yaml`

```yaml
# typescript-fetch options. Full list: config-help -g typescript-fetch
additionalProperties:
  npmName: "@plexsphere/sdk"
  npmVersion: 0.1.0
  supportsES6: true
  typescriptThreePlus: true
  withInterfaces: true
```

#### `.openapi-generator-ignore` (per language)

Declares which generated paths are **dropped** from `dist/<lang>/` before the overlay, so the
SDK repo's own copy survives the `rsync` (which runs without `--delete`). Useful to protect a
hand-maintained README, the SDK repo's CI under `.github/`, or a CSRF extension. Minimal:

```gitignore
# Generated notice/helper files we don't want:
.travis.yml
git_push.sh

# CI workflows and hand-maintained files the SDK repo owns:
.github/
README.md
```

> **Enforcement.** `scripts/generate-sdk.sh` reads this file and `rm -rf`s each listed path
> (one path per line; `#` comments and blank lines ignored; a trailing `/` is stripped) after
> generation. We do **not** pass openapi-generator's `--ignore-file-override`: it matches
> patterns relative to the ignore file's *own* directory, so an out-of-tree override never
> matches and the generator ships `.github/` (rejected without `workflow` scope on the PR
> token), `README.md`, etc. regardless. Keep entries to literal paths — full `.gitignore` glob
> syntax is not interpreted.

---

### Variant: npm wrapper

Instead of downloading the jar directly, you can use the official wrapper — it pins the
version via `openapitools.json`:

```bash
npm install @openapitools/openapi-generator-cli -g   # or locally as a devDependency
npx @openapitools/openapi-generator-cli version-manager set 7.22.0
```

`openapitools.json` (in the repo root):

```json
{
  "$schema": "https://raw.githubusercontent.com/OpenAPITools/openapi-generator-cli/master/apps/generator-cli/src/config.schema.json",
  "spaces": 2,
  "generator-cli": { "version": "7.22.0" }
}
```

Then invoke `npx @openapitools/openapi-generator-cli generate …` instead of `java -jar …`.
Both paths are equivalent; STACKIT uses the jar variant (no Node dependency) — this README
follows it.

---

## Plexsphere-specific considerations

These are the actual "gotchas". This is where the value lies beyond a bare
`openapi-generator generate`.

### OpenAPI 3.1 requires generator ≥ 7.x

3.1 introduces, among other things, `type` arrays (`type: [string, "null"]`), genuine JSON
Schema keywords, and `null` as a type. Older generators (≤ 6.x) handle this incorrectly.
**Always pin 7.x** and re-check the templates after generator upgrades (a Renovate comment
like STACKIT's helps keep the version current).

### No `servers` block

The spec deliberately sets no `servers` entry (the server URL is environment-dependent:
dev/staging/prod/on-prem). Consequence: generated clients have **no default host** and the
caller must set the base URL at runtime (Go: `Configuration.Host`/`Servers`, Python:
`Configuration(host=…)`, TS: `BasePath`/`Configuration`).

Two strategies:

1. **Leave the spec unchanged** (recommended) and document in the SDK README that the base
   URL must be set.
2. **Inject `servers` on download** — e.g. for a default prod URL. In `download-spec.sh`
   with `yq`:

   ```bash
   yq -i '.servers = [{"url": "https://api.plexsphere.com"}]' "$SPEC_FILE"
   ```

   Only do this if a sensible default URL actually exists; otherwise it's misleading.

### Authentication: Bearer (the SDK default) + cookie/CSRF

> **Decision (issue #7).** The generated Go and Python SDKs are **bearer-only**. plexsphere
> operator/machine clients authenticate with a bearer token; the cookie+CSRF flow is a
> browser-session concern and is deliberately **not** generated. No CSRF template override
> ships under `languages/{go,python}/templates/`, so there is nothing extra for the
> per-language `.openapi-generator-ignore` to protect. Rationale below.

**Bearer works out of the box.** The spec declares the security scheme `operatorBearer`
(HTTP Bearer, JWT) and applies it to the operator endpoints, so the generator emits the
`Authorization: Bearer …` path with no override — the caller only supplies the token:

```go
// Go: carry the token in the request context (plexsphere.ContextAccessToken).
ctx := context.WithValue(context.Background(), plexsphere.ContextAccessToken, "<token>")
// resp, httpResp, err := client.<Tag>API.<Operation>(ctx).Execute()
```

```python
# Python: set the token on the Configuration (access_token).
configuration = plexsphere.Configuration(host="https://…", access_token="<token>")
# with plexsphere.ApiClient(configuration) as api_client: ...
```

The SDK READMEs (plexsphere-sdk-go#2, plexsphere-sdk-python#2) document end-user usage; the
snippets above are the contract they build on.

**Why no CSRF override.** The spec's CSRF defence-in-depth (its top-level `description` and
the `Problem.code` taxonomy) requires state-changing **cookie-authenticated** `/v1/*`
requests to echo the `plexsphere_csrf` cookie in the `X-Plexsphere-CSRF` header and carry an
`Origin`/`Sec-Fetch-Site` signal, otherwise `403 application/problem+json`. It is not an
OpenAPI security scheme, so the generator emits nothing for it — which is correct here:

- The spec **exempts bearer-authenticated requests** from CSRF (browsers do not auto-attach
  `Authorization`). A bearer-only SDK makes only exempt requests.
- The `plexsphere_csrf` cookie is minted by the interactive sign-in flow and held by a
  browser session; a machine client never receives it, so it has nothing to echo.
- Echoing it would mean forking the generator's request template for both languages — a
  fragile, high-maintenance override (cf. the `languages/go/templates/api.mustache` header)
  for a code path no operator SDK exercises.

**If cookie auth is ever required**, add a request interceptor as a Mustache template
override under `languages/<lang>/templates/` that copies the `plexsphere_csrf` cookie into
the `X-Plexsphere-CSRF` header (plus the `Origin`/`Sec-Fetch-Site` signal), and list that
file in the per-language `.openapi-generator-ignore` so regeneration preserves it — the same
mechanism that already protects hand-maintained paths (see
[Step 6](#step-6--language-configuration--ignore-files)). This stays optional and unbuilt
until a cookie-auth use case appears.

### Error format `application/problem+json` (RFC 9457)

Every error response uses `application/problem+json`. The spec defines a single `Problem`
schema (RFC 9457), so the generator emits one typed error model with these members:

| Member     | Type    | Meaning |
|------------|---------|---------|
| `type`     | string  | URI reference identifying the problem class. |
| `title`    | string  | Short, human-readable summary. |
| `status`   | integer | HTTP status code; mirrors the response status. |
| `detail`   | string  | Human-readable explanation for this occurrence. |
| `instance` | string  | URI reference identifying this specific occurrence. |
| `code`     | string  | Optional plexsphere extension: the machine-readable code clients branch on (`csrf-token-mismatch`, `domain_slug_conflict`, …). |

`code` is the stable branch point — the spec enumerates a closed taxonomy per domain. The
SDKs surface the error body as the typed `Problem`; the SDK READMEs (plexsphere-sdk-go#2,
plexsphere-sdk-python#2) document this recipe:

```go
// Go: the returned error carries the decoded Problem model.
var apiErr *plexsphere.GenericOpenAPIError
if errors.As(err, &apiErr) {
    if p, ok := apiErr.Model().(plexsphere.Problem); ok {
        log.Printf("problem: status=%d code=%s", p.GetStatus(), p.GetCode())
    }
}
```

```python
# Python: deserialize the response body into the Problem model.
try:
    ...
except plexsphere.ApiException as e:
    problem = plexsphere.Problem.from_json(e.body)
    print(problem.status, problem.code)
```

### BUSL-1.1 license

The spec is under **BUSL-1.1**. Before publishing the SDKs, clarify the license of the
*generated code* with the rights holders and place an appropriate `LICENSE` into each SDK
repo (separate from the license of *this* generator repo).

---

## Versioning & reproducibility

Two things must be pinned for builds to be reproducible:

1. **Generator version** — in the `Makefile` (`GENERATOR_VERSION`) or `openapitools.json`.
   Renovate can update it automatically (a comment annotation like STACKIT's).
2. **Spec state** — `spec/plexsphere-v1.yaml` is committed, and `spec/spec-lock.json` records
   the source, `sha256`, API version, and fetch time. `make download-spec` rewrites the lock
   from the spec, so the two cannot silently drift.

### Lock-hash CI gate

`make check-spec-lock` recomputes the vendored spec's SHA-256 and asserts it equals the
`sha256` in `spec/spec-lock.json`. It is **offline and deterministic** — no network, no Java —
so [`validate.yaml`](.github/workflows/validate.yaml) runs it on every PR and a hand-edited
spec or a stale lock **fails the build**. This is the "spec unchanged" half of reproducibility.

Keeping the vendored spec *current* with upstream is the separate job of
[`update-spec.yaml`](.github/workflows/update-spec.yaml), which re-runs `make download-spec`
on a schedule and opens a PR when upstream changed. Drift from upstream therefore surfaces as
a reviewable PR, not as a red build on otherwise-unrelated PRs.

SDK versioning: SemVer per SDK, driven by the spec's `info.version` plus an own patch level.
On breaking spec changes → major bump of the SDK.

---

## CI/CD & publishing

GitHub Actions workflows under `.github/workflows/` form a two-step, spec-driven pipeline:

1. **`update-spec.yaml`** (scheduled) refreshes the vendored spec and opens a PR in *this*
   repo when it changed.
2. Merging that PR is a push to `spec/**`, which triggers **`generate.yaml`** to regenerate
   the SDKs and open PRs in the SDK repos.

So a spec refresh and the resulting SDK regeneration are two separately reviewable steps
rather than one weekly black box, and the SDKs are always built from the exact spec that was
reviewed and merged. `validate.yaml` gates spec PRs opened by hand.

### `validate.yaml` — PR gate

On every PR: `make check-spec-lock` (the vendored spec must match the `sha256` in the lock —
see [Lock-hash CI gate](#lock-hash-ci-gate)) → set up Java → `make validate-spec`. The lock
check runs first because it is offline and deterministic; a drifted spec fails the PR before
the generator jar is even fetched.

```yaml
name: validate
on:
  pull_request:
permissions:
  contents: read          # read-only: the job only checks out and validates
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make check-spec-lock   # spec sha256 must match spec/spec-lock.json
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - run: make validate-spec
```

### `update-spec.yaml` — refresh the vendored spec

Scheduled weekly (Mondays 06:00 UTC) and runnable on demand (`workflow_dispatch`). It sets up
Java, runs `make download-spec` to fetch and pin the upstream spec, then `make validate-spec`
to reject a spec the pinned generator cannot parse *before* it reaches a PR. If `spec/**`
changed, [`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request)
opens — or updates — a single PR in this repo (`add-paths: spec` keeps the commit to the spec;
the generator jar fetched into `bin/` is gitignored and never committed). The PR appears
exactly when the upstream spec changed; merging it is what drives regeneration.

This uses the built-in `GITHUB_TOKEN` (`contents: write`, `pull-requests: write`) because the
PR stays within this repo. A PR opened by `GITHUB_TOKEN` does not itself trigger other
workflows, so `validate.yaml` does not re-run on it — which is why the spec is validated
inline here. When a human merges the PR, the resulting push to `main` is an ordinary event
and triggers `generate.yaml` normally.

```yaml
name: update-spec
on:
  workflow_dispatch:
  schedule:
    - cron: "0 6 * * 1"            # weekly, Mondays 06:00 UTC
permissions:
  contents: write                 # push the spec branch …
  pull-requests: write            # … and open the PR (both in this repo)
jobs:
  update-spec:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: "17" }
      - run: make download-spec
      - run: make validate-spec
      # open/update a PR touching only spec/ (peter-evans/create-pull-request,
      # pinned by SHA), so merging it triggers generate.yaml.
```

### `generate.yaml` — regenerate & open PRs

Triggered by a push to `spec/**` on `main` (i.e. when a spec refresh is merged) and runnable
on demand (`workflow_dispatch`). A matrix job per language (`go`, `python`) sets up Java 17
and the language toolchain and runs `make generate-<lang>` against the **vendored** spec — no
re-download, so the SDKs are built from the exact spec that was reviewed and merged (see
[Versioning & reproducibility](#versioning--reproducibility)). It then smoke-builds the result
(see [Tests & validation](#tests--validation)). The smoke check **gates** the pull request: a
non-building SDK fails the job before any PR is opened.

On a successful build the generated `dist/<lang>/` tree is overlaid onto a checkout of the
matching SDK repo (`plexsphere-sdk-<lang>`) and
[`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request)
opens — or updates — a single PR there. The overlay uses `rsync` **without** `--delete`, so
files the generator deliberately omits (the SDK's hand-maintained `README.md`, protected by
`languages/<lang>/.openapi-generator-ignore`) and repo meta (`.git/`, `.github/`) survive
regeneration. The action commits only when the overlay produces a diff, so a PR appears
exactly when the regenerated SDK changed. This mirrors STACKIT's `sdk-pr.yaml` +
`sdk-create-pr.sh` for a single spec.

The canonical definition is
[`.github/workflows/generate.yaml`](.github/workflows/generate.yaml); its shape, condensed:

```yaml
name: generate
on:
  workflow_dispatch:
  push:
    branches: [main]
    paths: ["spec/**"]            # fires when a merged spec refresh lands
permissions:
  contents: read                  # writes go to the SDK repos via SDK_PR_TOKEN
jobs:
  generate:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix: { lang: [go, python] }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: "17" }
      - if: matrix.lang == 'go'
        uses: actions/setup-go@v5
        with: { go-version: stable }
      - if: matrix.lang == 'python'
        uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: make generate-${{ matrix.lang }}   # vendored spec, no re-download
      # smoke-build, then overlay dist/<lang>/ into a plexsphere-sdk-<lang>
      # checkout and open/update a PR (peter-evans/create-pull-request,
      # pinned by SHA; needs the SDK_PR_TOKEN secret).
```

#### Required secrets

| Secret | Purpose | Access required |
|--------|---------|-----------------|
| `SDK_PR_TOKEN` | Push the regenerated branch and open/update the PR in each SDK repo | `contents: write` **and** `pull-requests: write` on **both** `plexsphere/plexsphere-sdk-go` and `plexsphere/plexsphere-sdk-python` |

Use a fine-grained Personal Access Token scoped to the two SDK repos, or a GitHub App
installation token. The built-in `GITHUB_TOKEN` is **not** usable here: it cannot write to
other repositories, and a PR it opened would not trigger the SDK repos' own CI gate. A token
distinct from `GITHUB_TOKEN` is also what makes those gating workflows run on the
regeneration PR.

**Publishing** per language: Go → git tag in the SDK repo (Go modules pull straight from
git); Python → build + `twine upload` to PyPI; TypeScript → `npm publish`. This is best done
in the respective **SDK repo**, not in the generator repo.

---

## Tests & validation

- **Spec validation:** `make validate-spec` (mandatory PR gate).
- **Does the SDK compile?** Go: `go build ./...`; Python: `pip install -e . && python -c "import plexsphere"`; TS: `npm run build`. These smoke checks belong in CI right after generation.
- **Optional Spectral lint** for spec style/best practices.
- **Diff review:** submit the generated code as a PR into the SDK repo — a human review of
  the diff catches unexpected breaking changes.

---

## Adding more languages

A new language (e.g. Java, Rust, C#, Kotlin, PHP) requires only:

1. Find the generator name: `java -jar bin/openapi-generator-cli-<v>.jar list`.
2. Add `scripts/languages/<lang>.sh` with a `generate_sdk` function (generator flags +
   post-processing for that language).
3. Add `languages/<lang>/openapi-generator-config.yaml` (+ optional `.openapi-generator-ignore`,
   `templates/`). Options via `config-help -g <generator>`.
4. Add `<lang>` to `LANGUAGES` in the `Makefile` and, if applicable, to the CI matrix.

**Optional — split by tag:** Since plexsphere has 24 tags, you could produce sub-packages
per domain (`--global-property` for filtering, or split the spec by tag beforehand, e.g.
with `openapi-format`/`redocly split`). Recommendation: **start with one package per
language** and split only when needed — it keeps the generator simple.

---

## Differences from STACKIT

| Aspect | STACKIT | plexsphere (this repo) |
|--------|---------|------------------------|
| Number of specs | many (one per service) | **one** monolithic spec |
| Spec acquisition | `download-oas.sh` clones a spec repo, `api-versions-lock.json` selects versions per service | `download-spec.sh` downloads **one** file + `spec-lock.json` (sha256) |
| Output | many modules/packages, `go.work` workspace, "compat-layer", blocklist | **one** SDK per language, no workspace, no blocklist |
| Custom generator | `CustomRegionGenerator.java` (regions) | not needed (standard generators suffice) |
| OpenAPI version | 3.0/3.1 | **3.1.0** (→ generator ≥ 7.x mandatory) |
| Auth | varies per service | Bearer (modeled) + cookie/CSRF (prose, optional template override) |
| Retained | Makefile structure, jar pinning, per-language config/templates, CI PRs, Renovate | ✅ all adopted |

In short: same architecture, far fewer moving parts.

---

## References

- plexsphere OpenAPI spec: <https://api.plexsphere.com/plexsphere-v1.yaml> (docs at <https://api.plexsphere.com>)
- Model: <https://github.com/stackitcloud/stackit-sdk-generator>
- OpenAPI Generator: <https://openapi-generator.tech> · generators: <https://openapi-generator.tech/docs/generators> · file post-processing: <https://openapi-generator.tech/docs/file-post-processing>
- npm wrapper: <https://github.com/OpenAPITools/openapi-generator-cli>
- OpenAPI 3.1 specification: <https://spec.openapis.org/oas/v3.1.0>
- RFC 9457 (Problem Details): <https://www.rfc-editor.org/rfc/rfc9457>
- BUSL-1.1: <https://spdx.org/licenses/BUSL-1.1.html>
