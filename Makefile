# Configuration ------------------------------------------------------------
SPEC_URL        ?= https://api.plexsphere.com/plexsphere-v1.yaml
SPEC_FILE       ?= spec/plexsphere-v1.yaml
SPEC_LOCK       ?= spec/spec-lock.json

# Pinned generator version (>=7.x because of OpenAPI 3.1!)
GENERATOR_VERSION ?= 7.22.0

LANGUAGES       := go python

.DEFAULT_GOAL := help

# Targets ------------------------------------------------------------------
# Note: generate-<lang> targets are intentionally NOT marked .PHONY — GNU Make
# skips implicit/pattern-rule search for .PHONY targets, which would stop the
# generate-% rule below from matching them (e.g. `make generate-go`).
.PHONY: help download-spec validate-spec generate-all

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
