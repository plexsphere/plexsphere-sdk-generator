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
    └── generate.yaml             # regenerate on spec update + open PRs
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
.PHONY: help download-spec validate-spec generate-all $(addprefix generate-,$(LANGUAGES))

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

download-spec: ## Download the OpenAPI spec and pin it (sha256) in spec/spec-lock.json
	@SPEC_URL="$(SPEC_URL)" SPEC_FILE="$(SPEC_FILE)" SPEC_LOCK="$(SPEC_LOCK)" \
	  scripts/download-spec.sh

validate-spec: ## Validate the vendored spec
	@SPEC_FILE="$(SPEC_FILE)" GENERATOR_VERSION="$(GENERATOR_VERSION)" \
	  scripts/validate-spec.sh

generate-all: $(addprefix generate-,$(LANGUAGES)) ## Generate all SDKs

generate-%: ## Generate the SDK for <lang> (e.g. make generate-go)
	@SPEC_FILE="$(SPEC_FILE)" GENERATOR_VERSION="$(GENERATOR_VERSION)" \
	  scripts/generate-sdk.sh "$*"
```

---

### Step 2 — `scripts/download-spec.sh`

Downloads the spec, writes it into `spec/`, computes the SHA-256, and creates a lock file
for reproducibility. (Optional: inject a `servers` block here — see
[no `servers` block](#no-servers-block).)

```bash
#!/usr/bin/env bash
set -euo pipefail

SPEC_URL="${SPEC_URL:?SPEC_URL must be set}"
SPEC_FILE="${SPEC_FILE:-spec/plexsphere-v1.yaml}"
SPEC_LOCK="${SPEC_LOCK:-spec/spec-lock.json}"

mkdir -p "$(dirname "$SPEC_FILE")"

echo ">> Downloading spec from ${SPEC_URL}"
curl -fsSL "$SPEC_URL" -o "$SPEC_FILE"

# sha256 cross-platform
if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$SPEC_FILE" | awk '{print $1}')"
else
  SHA="$(shasum -a 256 "$SPEC_FILE" | awk '{print $1}')"
fi

# Pull the API version from the spec (info.version), fall back to "unknown"
API_VERSION="$(grep -m1 -E '^  version:' "$SPEC_FILE" | sed -E 's/.*version:[[:space:]]*//' | tr -d '"' || true)"
API_VERSION="${API_VERSION:-unknown}"
FETCHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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

### Step 3 — `scripts/validate-spec.sh`

Uses the generator itself to validate (no extra tool required). Optionally
[Spectral](https://github.com/stoplightio/spectral) can be hooked in here as well.

```bash
#!/usr/bin/env bash
set -euo pipefail

SPEC_FILE="${SPEC_FILE:-spec/plexsphere-v1.yaml}"
GENERATOR_VERSION="${GENERATOR_VERSION:?GENERATOR_VERSION must be set}"
JAR="bin/openapi-generator-cli-${GENERATOR_VERSION}.jar"

if [ ! -f "$JAR" ]; then
  echo ">> Downloading openapi-generator-cli ${GENERATOR_VERSION}"
  mkdir -p bin
  curl -fsSL \
    "https://repo1.maven.org/maven2/org/openapitools/openapi-generator-cli/${GENERATOR_VERSION}/openapi-generator-cli-${GENERATOR_VERSION}.jar" \
    -o "$JAR"
fi

echo ">> Validating ${SPEC_FILE}"
java -jar "$JAR" validate --recommend -i "$SPEC_FILE"
```

> The jar download is repeated in `generate-sdk.sh`; if you prefer, extract it into a small
> `scripts/_fetch_jar.sh` and source it from both places.

---

### Step 4 — `scripts/generate-sdk.sh` (orchestrator)

Picks the generator version, makes the jar available, and calls the language-specific
script — exactly the pattern from STACKIT's `generate-sdk.sh`, just without the
multi-service loop.

```bash
#!/usr/bin/env bash
set -euo pipefail

LANGUAGE="${1:?Usage: generate-sdk.sh <language>}"
SPEC_FILE="${SPEC_FILE:-spec/plexsphere-v1.yaml}"
GENERATOR_VERSION="${GENERATOR_VERSION:-7.22.0}"

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

JAR="bin/openapi-generator-cli-${GENERATOR_VERSION}.jar"
LANG_SCRIPT="scripts/languages/${LANGUAGE}.sh"

command -v java >/dev/null 2>&1 || { echo "! Java not installed."; exit 1; }
[ -f "$SPEC_FILE" ]   || { echo "! Spec ${SPEC_FILE} missing. Run 'make download-spec' first."; exit 1; }
[ -f "$LANG_SCRIPT" ] || { echo "! No support for '${LANGUAGE}' (${LANG_SCRIPT} missing)."; exit 1; }

# Make the generator available
if [ ! -f "$JAR" ]; then
  echo ">> Downloading openapi-generator-cli ${GENERATOR_VERSION}"
  mkdir -p bin
  curl -fsSL \
    "https://repo1.maven.org/maven2/org/openapitools/openapi-generator-cli/${GENERATOR_VERSION}/openapi-generator-cli-${GENERATOR_VERSION}.jar" \
    -o "$JAR"
fi

OUT_DIR="dist/${LANGUAGE}"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo ">> Generating ${LANGUAGE} SDK into ${OUT_DIR}"
# Load the language-specific function and run it
# shellcheck source=/dev/null
source "$LANG_SCRIPT"
generate_sdk "$JAR" "$SPEC_FILE" "$OUT_DIR"

echo ">> Done: ${OUT_DIR}"
```

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

Controls which generated files are **not** overwritten (syntax like `.gitignore`). Useful to
protect a hand-maintained README or a CSRF extension. Minimal:

```gitignore
# Generated notice/helper files we don't want:
.travis.yml
git_push.sh

# Add your own hand-maintained files here so they aren't overwritten:
# README.md
```

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

### Authentication: Bearer + cookie/CSRF

The spec declares a security scheme `operatorBearer` (HTTP Bearer, JWT). The generator
produces this correctly — callers set an access token, sent as `Authorization: Bearer …`.

**Not** modeled (only documented in the spec's description) is the **cookie+CSRF flow**:
state-changing, cookie-authenticated `/v1/*` requests must additionally echo the
`plexsphere_csrf` cookie in the `X-Plexsphere-CSRF` header and send an Origin/`Sec-Fetch-Site`
signal; otherwise `403 application/problem+json`. Bearer requests are exempt.

Since this is not an OpenAPI security scheme, the generator produces **nothing** for it.
Options:

- **Recommended for SDKs:** use bearer/token auth (the common case for machine/operator
  clients) — then no CSRF is needed.
- **If cookie auth is required:** add a small request interceptor as a **template override**
  (in `languages/<lang>/templates/`) that sets `X-Plexsphere-CSRF` from the cookie. Protect
  such hand-maintained spots via `.openapi-generator-ignore`.

### Error format `application/problem+json` (RFC 9457)

Error responses consistently use `application/problem+json`. The generator produces the
corresponding models (e.g. a `Problem` schema with `type`, `title`, `status`, `detail`,
`code`). The SDK README should explain how to deserialize the error body into this model so
that users can act on the `code` values (`csrf-token-mismatch`, etc.).

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
   the source, `sha256`, and fetch time. CI can enforce that `download-spec` produces no diff
   (= spec is current) and that the hash matches the lock (= unchanged).

SDK versioning: SemVer per SDK, driven by the spec's `info.version` plus an own patch level.
On breaking spec changes → major bump of the SDK.

---

## CI/CD & publishing

Recommended GitHub Actions workflows under `.github/workflows/`:

### `validate.yaml` — PR gate

On every PR: set up Java → `make download-spec` (or use the vendored spec) →
`make validate-spec`. Optionally a diff check that the vendored spec matches the hash in the
lock.

```yaml
name: validate
on: { pull_request: {} }
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: "17" }
      - run: make validate-spec
```

### `generate.yaml` — regenerate & open PRs

Scheduled (cron) or via `workflow_dispatch`: re-download the spec → if there's a diff →
generate per language → commit the result into the respective SDK repo and open a PR (e.g.
via `peter-evans/create-pull-request` or `gh pr create`). This mirrors STACKIT's
`sdk-pr.yaml` + `sdk-create-pr.sh`.

Rough sketch per language:

```yaml
name: generate
on:
  workflow_dispatch: {}
  schedule: [{ cron: "0 6 * * 1" }]   # weekly
jobs:
  generate:
    runs-on: ubuntu-latest
    strategy:
      matrix: { lang: [go, python, typescript] }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: "17" }
      - run: make download-spec
      - run: make generate-${{ matrix.lang }}
      # -> push dist/${{ matrix.lang }} into the SDK repo + open a PR (needs a token/secret)
```

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
