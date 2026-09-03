# cotique/bitbucket — initialize, verify, and publish a standalone Kickside module.
# Backend-only, no web component: matches the real reference providers that
# need no custom Connect/picker UI (kickside/discord, kickside/slack, etc. —
# see BUILD-NOTES.md), so there's no build/typecheck step and no --embed flag.
MODULE  := bitbucket
LINT_NS := cotique.bitbucket.*
TYPE    := plugin
VIS     := private

# pipefail lets the test targets both stream runner output and keep its exit
# code while grepping the log afterwards.
SHELL := bash
.SHELLFLAGS := -o pipefail -ec

.PHONY: init setup check lint test test-pg postgres-up postgres-down verify release-check publish
init:
	node scripts/init-module.mjs --organization "$(ORG)" --module "$(MODULE_NAME)" --title "$(TITLE)" $(if $(NAMESPACE),--namespace "$(NAMESPACE)",) $(if $(TAG),--tag "$(TAG)",) $(if $(GITHUB_OWNER),--github-owner "$(GITHUB_OWNER)",)
# The harness `wippy update` runs twice, deliberately: a from-scratch run
# (no lock file yet) does not scan the test/.wippy.yaml workspace
# replacement for the module-under-test's own transitive deps (resolves
# only the harness's own 3 declared deps, 5 modules total) — confirmed
# empirically, see BUILD-NOTES.md. A second run, once *some* lock already
# exists, does pick up the replacement path and expands to the full graph
# (kickside/connection, kickside/component, and their own transitive deps).
setup:
	wippy update
	cd test && wippy update
	cd test && wippy update --config .wippy.yaml
check:
	node scripts/check-module.mjs
	node scripts/test-initializer.mjs
# Scoped to this module's own namespace. Unscoped `wippy lint` checks every
# resolved dependency's Lua too — kickside/connection pulls in kickside/core,
# which has a real, pre-existing type error in
# kickside.core.projections.persist:catchup (confirmed present as of this
# writing, independently reproducing the same finding cotique/eng-metrics'
# own BUILD-NOTES.md #7 documents) — we can only act on our own code, so
# that's what gets linted.
lint:
	wippy lint --ns "$(LINT_NS)"
# The runner exits 0 when it discovers zero tests, which turns a broken
# discovery setup into a false-green run. An empty discovery is always a
# defect here — the template ships suites — so both targets fail on it.
test:
	cd test && wippy test 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log
test-pg:
	cd test && wippy test --profile postgres 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log
postgres-up:
	docker compose -f compose.test.yaml up -d --wait
postgres-down:
	docker compose -f compose.test.yaml down -v
verify: setup check lint test
release-check: verify
	wippy auth status
	wippy publish --dry-run --create --module-visibility $(VIS) --module-type $(TYPE)
publish:
	node scripts/check-module.mjs
	wippy auth status
	wippy publish --create --module-visibility $(VIS) --module-type $(TYPE)
