# Build notes — cotique/bitbucket-provider

This module is a Bitbucket Cloud connector for the Kickside platform: a
`kickside.connection` provider (app password or access token) plus a
`kickside.data:pullable` source publishing a selected repository's pull
requests as an automation port. Read alongside `README.md` and
`AGENTS.md`.

## Deliverable checklist

- [x] `wippy.yaml` — `description` rewritten from the template's log-sink
      placeholder; `repository:` fixed from the template's guessed
      `https://github.com/cotique/bitbucket-provider` to the real
      `https://github.com/cotique/kickside-bitbucket-provider`.
- [x] `src/` implements the connection + source structure below.
- [x] `test/` — colocated-logic tests + harness registry-shape test,
      `make verify` passes clean end to end (41/41 tests on SQLite and the
      shared Postgres instance) — see "RESOLVED: pre-existing lint errors
      in a transitive platform dependency" below for the Makefile fix this
      needed.
- [x] `BUILD-NOTES.md` (this file).
- [x] Local commit, no push.

## Components checked via `wippy search`

`wippy search bitbucket` and `wippy search gitlab` were both empty
immediately before starting (re-verified 2026-09-02, matching the brief's
own last-confirmed-empty timestamp) — no existing Bitbucket/GitLab
connector on the Hub to reuse or conflict with.

## Structure built

```
src/
  _index.yaml            root: definition, deps, api_router/ui_server requirements, UI entries
  api/get_status.lua      GET /bitbucket-provider/status — static module identity (no DB)
  security/_index.yaml    endpoint access policy + user_security_scope requirement
  client/
    types.lua              base URL, auth-mode constants, PR state map
    output.lua              redact() — strips credential-shaped fields from any table
    data_error.lua          HTTP/transport failure -> {code,message,retriable,scope}
    api.lua                 low-level REST client (http_client + json + base64)
    transport.lua           component_id/credentials -> configured client:api instance
  connection/
    connection_lib.lua      ctx.get("component_id") -> transport.for_component
    get_status.lua          delegates to kickside.connection:base_connection
    delete.lua               delegates to kickside.connection:base_connection
    test_connection.lua      live GET /user
    discover_resources.lua   live GET /repositories?role=member, normalized
    _index.yaml               bitbucket_connection contract.binding + credential_schema
  source/
    pull_core.lua            fetch_page/list_all/normalize_item/normalize_key — fully tested
    pull.lua                 pull()/pull_keys() — thin kickside.data:pullable wrappers
    _index.yaml               repo_pulls_source contract.binding + repo_pulls automation port
ui/                          kept from the template, adjusted to the new static status shape
test/
  src/_index.yaml            harness resources + bootloader parameter wiring
  src/wiring_test.lua         registry-shape assertions
  src/{output,data_error,transport,discover_resources,pull_core}_test.lua
                              colocated logic tests (see "OPEN: exclude_meta" below for why
                              they live here rather than next to their source)
  src/wait_for_boot.lua       polls registry.get instead of SQL (no migrations in this module)
```

Removed from the template's demo scaffold per the brief: `src/migrations/`,
`src/persist/`, `src/sink/`, `src/blocks/`, the `log`/`log_sink` registry
entries, the `target_db` requirement, `wippy/migration` dependency, and
`test/src/log_test.lua`. `get_status.lua` was adjusted to return a static
identity/capability snapshot instead of `repo.count()` (this module owns no
SQL tables — the pullable contract's own doc comment: "Engine owns cursor,
lease, schedule, dedup, id-map, and sink routing"); `ui/src/types.ts` and
`ui/src/app/bitbucket-provider.vue` were updated minimally to match.

## Deliberate scope decisions (not oversights)

- **Bitbucket Cloud only**, `api.bitbucket.org/2.0`. Server/Data Center uses
  `/rest/api/1.0` and a different auth model entirely — out of scope; a
  Server/DC binding would be a separate module if ever needed.
- **No agent-tool traits** (`kickside.bitbucket_provider.traits:*` reader/
  writer/manager, matching `kickside.github.traits:*`) — explicitly out of
  scope per the brief.
- **Read-only, always.** No write/comment/approve/merge methods anywhere,
  matching eng-metrics SPEC.md decision B0. Both credential modes' `help`
  text tells the user to scope the token/app password to
  `Repositories: Read` + `Pull requests: Read` only.

## OPEN: `kickside.data:pullable` request/response shape

**Partially resolved during this build — new, confirmed information below.**

We do not have access to `kickside.data:pullable`'s real Lua source. The
reference module `kickside/github` is a packed Hub module — `wippy registry
show <id> --json` returns `"data": null` for every entry in it, reconfirmed
during this build for both `kickside.data:pullable` itself and every
`kickside.github.*` entry (temporarily added via `wippy add kickside/github`
to inspect its registry shape, then removed — see below).

**Confirmed, not inferred, this time:**

- Temporarily installing `kickside/github` (`wippy add kickside/github` /
  `wippy install`, `wippy.lock` restored and the temp dependency removed
  afterward — `wippy.lock` is git-ignored so this left no trace) and running
  `wippy registry list --ns "kickside.github*"` returned the **exact same
  directory/file/entry-naming shape** this module was built to: `client:api`,
  `client:data_error`, `client:output`, `client:transport`, `client:types`,
  `connection:connection_lib`, `connection:get_status`, `connection:delete`,
  `connection:test_connection`, `connection:discover_resources`,
  `connection:<provider>_connection`, `source:pull_core`,
  `source:pull_items`, `source:pull_keys`, `source:<x>_source` (binding),
  `source:<x>` (automation port). Every comment on those entries matched the
  brief's description almost verbatim (e.g. `client:output`: "Safe GitHub
  tool output encoding (redacts secrets, truncates)"; `client:data_error`:
  "Maps GitHub client results onto kickside.data DataError envelopes").
  **The structure is now doubly confirmed, not a guess.**
- **NEW finding, confirmed live against the real contract, not a guess:**
  booting this module in the standalone test harness against the real,
  installed `kickside.data:pullable` contract definition (`kickside/contract`
  0.1.30) and attempting to bind both `pull` and `pull_keys` under it in
  `source/_index.yaml`'s `contract.binding` produced a hard registry-commit
  rejection:
  ```
  transaction rejected for registry.commit: bound method is not defined in
  contract definition: cotique.bitbucket_provider.source:repo_pulls_source
  binds kickside.data:pullable.pull_keys
  ```
  i.e. **`kickside.data:pullable` accepts exactly one bound method, `pull`.**
  `pull_keys` is NOT part of this contract's method list, despite
  `kickside/github` shipping an identical `pull_keys` function.lua entry
  alongside `pull_items`. This module's `source/_index.yaml` now binds only
  `pull`; `pull_keys` (`source/pull.lua`'s second exported function) is kept
  as a plain, unbound registered entry for structural parity with
  `kickside/github`, but nothing calls it through the pullable contract.
  **Still open:** exactly how Data Sync's reconcile path is meant to reach a
  keys-only listing (a naming convention on the entry id, a second field on
  the `kickside.automation.port` entry, folding a `keys_only`/`mode` flag
  into the single `pull` request instead — genuinely unknown). Whoever
  resolves this should also revisit whether `pull_keys` is a real dead
  end (delete it) or the reconcile mechanism becomes clear (wire it
  properly) — do not leave it a copy-pasted-but-unreachable entry
  indefinitely.
  `kickside.data:data_connector_manifest_schema` (a JSON-Schema
  `registry.entry`, visible even though the module is packed — its
  `meta.json_schema` is plain data, not Lua) describes a *different*,
  consolidated "data.connector" manifest shape (`connection`/`sources`/
  `sinks`/`tools` all under one entry) that `kickside/github` does **not**
  use (its registry has no such entry). It may be a newer/alternative
  registration path for a different family of connectors; it does not
  resolve the `pull_keys` question and was not adopted here since
  `kickside/github` itself doesn't use it.
- **Still inferred, not confirmed:** the request/response envelope of the
  one confirmed method, `pull` itself — request `{ config, cursor }`,
  success `{ success = true, items, next_cursor, has_more }`, failure
  `{ success = false, error = { code, message, retriable, scope } }`. This
  is inferred by analogy to the real, verified `kickside.data:writable.write`
  envelope (the template's own `src/sink/write.lua` before this module
  removed the demo sink; the failure shape is confirmed generic across
  `kickside.data:*` per `docs/kickside-development/02-contracts-and-ports.md`).
  A large, impossible-to-miss comment sits directly above `pull()`/
  `pull_keys()` in `src/source/pull.lua` restating exactly this.
- **What would fully resolve it:** real source/repo access to
  `git.wippy.ai/kickside/providers` (kickside/github's actual repo, per the
  eng-metrics precedent this brief pointed at), or a working Keeper console
  against a booted host with the trait to inspect a live `pull()` call's
  actual request/response.
- **Kept cleanly separated per the brief's instruction:** `pull_core.lua`
  (REST calls, pagination, item/key normalization) has zero dependency on
  this guess and is independently unit-tested against a fake `client:api`
  double (`test/src/pull_core_test.lua`, 12 cases). Only `pull()`/
  `pull_keys()` in `source/pull.lua` depend on the still-inferred envelope.

## OPEN: `required_if` credential_schema syntax

Not independently verifiable. Checked, in order:
1. `docs/kickside-development/04-connections-and-integrations.md` — states
   the create policy "enforces `required`, type, `select` options, and
   `required_if`" but gives no syntax example beyond the generic mention.
2. `docs/kickside-development/17-settings.md` — a different subsystem
   (admin settings, not connection credential_schema); no `required_if`
   there at all.
3. `docs/kickside-development/07-frontend-and-web-components.md` — no
   `required_if` mention.
4. The one real, inspectable `credential_schema` (kickside/github's
   `github_connection` binding, pulled via the same temporary
   `wippy add kickside/github` used above) has a single field (`token`) —
   no `required_if` usage to observe, since GitHub only has one credential
   mode.
5. `wippy.ai/llm/toc` (the live platform doc search) has no page on
   `credential_schema`, `required_if`, connection providers, or select-field
   form syntax at all — checked directly, not assumed.

Given no real example or spec is reachable, `connection/_index.yaml`'s
`credential_schema` uses the exact `{ field: value }` shape given in the
provider brief (`required_if: { auth_mode: app_password }`), with a comment
directly above the block stating plainly that this is unverified. If it
turns out not to parse against the real `create_policy` validator, only that
YAML block needs to change — `client:transport.for_credentials` (the actual
auth-mode branch logic) is unit-tested directly against plain credential
tables and does not depend on this schema's syntax being right.

## Empirically-verified findings (live calls, 2026-09-02)

### Bitbucket's undocumented default `state` behavior — verified against the real repo

The provider brief asked this to be checked empirically against
`atlassian/atlassian-plugins` rather than assumed. Done during this build:

- `GET /repositories/atlassian/atlassian-plugins/pullrequests?pagelen=1`
  (no `state` param) → `"size": 6`, the one returned item has
  `"state": "OPEN"`.
- `GET /repositories/atlassian/atlassian-plugins/pullrequests?state=MERGED&pagelen=1`
  → `"size": 866`, the one returned item has `"state": "MERGED"`.

**Confirmed: omitting `state` returns OPEN pull requests only** (a real,
large behavioral difference — 6 vs. 866 — not just a coincidence of which
item sorts first). `source/_index.yaml`'s `repo_pulls` automation port
`config_schema.state` field documents this explicitly; `pull_core.lua`
passes `config.state` straight through as Bitbucket's own query param when
set, and does not set it when absent.

### Pagination and field-shape findings (from the shared brief, reused directly)

- Response body carries `{ values, pagelen, size, page, next }`; `next` is a
  complete absolute URL, followed literally by `client:api`/`pull_core`, never
  reconstructed. `size` is present but not used for loop termination — see
  `pull_core.fetch_page`/`list_all`, which stop purely on `next` being absent.
- Auth: `app_password` mode → HTTP Basic
  (`Authorization: Basic base64(username:app_password)`); `access_token`
  mode → `Authorization: Bearer <token>`. Both implemented in `client/api.lua`.
- Field mapping (`pull_core.normalize_item`): `author.display_name`,
  `source.branch.name`, `destination.branch.name`, `created_on`/`updated_on`
  (note the `_on` vs. the normalized shape's `_at`), `links.html.href`.
- `merged_at`: Bitbucket's PR payload carries no distinct "merged at"
  timestamp — only `updated_on` and a nested `merge_commit` once merged.
  `normalize_item` sets `merged_at = updated_on` only when
  `state == "MERGED"`, else `nil`. This is a documented approximation, not a
  silent guess — restated in a code comment at the mapping site.
- State mapping: `OPEN -> open`, `MERGED -> merged`, `DECLINED -> declined`,
  `SUPERSEDED -> declined`. The `SUPERSEDED` collapse is a real information
  loss (a superseded PR is not the same thing as a declined one), called out
  explicitly in `client/types.lua` and `pull_core.lua`.

## RESOLVED: pre-existing lint errors in a transitive platform dependency

`make verify` originally reached `lint` and failed there. This was a
**genuine external blocker**, not a defect in this module's own source —
verified as follows, and independently reproducing the exact finding
`cotique/eng-metrics`' own `docs/BUILD-NOTES.md` #7 documents for the same
`kickside.core.projections.persist:catchup` bug:

1. `wippy lint --ns "cotique.bitbucket_provider*"` → **`No issues found`,
   `Checked 56 entries`.** This module's own code lints completely clean.
2. `wippy lint --ns "kickside.core.*"` → the exact same 3 errors that show
   up in the bare `wippy lint` run, all inside
   `kickside.core.projections.persist:catchup` (a packed Hub module,
   `kickside/core@0.1.94`):
   - `argument 1: expected sql.Transaction, got any` at line 1191
   - `cannot assign unknown to string` at line 1795
   - `no method message` at line 1795 (same `(reason :: error):message()`
     expression as the previous error)
3. Removing this module's `kickside/connection`/`kickside/component`
   dependencies and re-running `wippy update` resolves a graph of **1
   module** (`kickside/contract` alone — no `kickside/core` at all). Adding
   them back is what pulls `kickside/core@0.1.94` in transitively. In other
   words: **this module cannot implement the mandated
   `kickside.connection:connection` provider pattern (which requires
   `kickside/connection` and, via `component.get_private_context`,
   `kickside/component`) without transitively depending on `kickside/core`,
   and the currently-published `kickside/core@0.1.94` has pre-existing type
   errors unrelated to anything in this module.**
4. The one remaining diagnostic (`wippy.session.process:message_handlers`
   inter-function fixpoint warning) is a **warning**, confirmed to exit 0 on
   its own (`wippy lint --ns "wippy.session.*"` → 1 warning, exit 0) — it is
   pre-existing platform noise unrelated to this module and does not block
   anything.

**Not fixable inside `kickside/core` itself.** It's a packed, third-party,
published Hub dependency — its source is not ours to edit, and `version: "*"`
(the platform convention this repo's `AGENTS.md` mandates — "Never copy an
exact resolved version from a lock into source") means we cannot responsibly
pin around it either, since an older `kickside/core` might lack APIs
`kickside/connection`/`kickside/component` now need, or might carry the same
bug.

**Fix applied (matching `cotique/eng-metrics`' own precedent exactly):**
scoped the Makefile's `lint` target to this module's own namespace —
`wippy lint --ns "cotique.bitbucket_provider.*"` (added a `LINT_NS` var,
same pattern as eng-metrics' Makefile) — since we can only act on our own
code, that's what gets linted. Re-verified after the fix:
`wippy lint --ns "cotique.bitbucket_provider.*"` → `No issues found, Checked
50 entries`, and the full `make verify` now passes end to end (41/41 tests on
both SQLite and the shared Postgres instance). Re-run bare `wippy lint` after
any future `kickside/core` upgrade to check whether the upstream bug has been
fixed — if so, the Makefile scoping can be relaxed back to unscoped, though
there's no urgency to do so.

## Harness-wiring findings (useful for the next module built from this template)

Two real platform quirks were hit and worked around, both confirmed by
direct, repeatable experimentation (not guesses):

1. **`wippy update`'s workspace-replacement scanning needs a pre-existing
   lock file to activate.** A from-scratch `wippy update --config
   .wippy.yaml` inside `test/` (no `wippy.lock` yet) resolves only the
   harness's own 3 declared deps (5 modules total) — it does **not** scan
   `test/.wippy.yaml`'s `workspace.replacements` target for the
   module-under-test's own `ns.dependency` entries. Running `wippy update`
   a **second** time, once *any* `wippy.lock` already exists, does pick up
   the replacement and correctly expands to the full transitive graph (16
   modules here). This was reproduced repeatedly (delete lock → bare
   update → 5 modules; run update again with `--config` → 16 modules).
   `Makefile`'s `setup:` target now runs `cd test && wippy update` (bare)
   immediately followed by `cd test && wippy update --config .wippy.yaml`
   to make this reliable rather than order-dependent on developer luck.
   This is a fix to the shipped template Makefile, not a workaround.
2. **`wippy.yaml`'s `exclude_meta.type: [test]` is applied even through a
   `workspace.replacements` load, not just at publish time.** A colocated
   `meta.type: test` entry declared inside this module's own
   `src/**/_index.yaml` never reaches the registry the standalone harness's
   `wippy test` run sees — confirmed by temporarily removing `exclude_meta`
   from `wippy.yaml` and watching 5 previously-invisible test entries appear
   in `wippy registry list --meta "type=test"`. This directly contradicts
   the "for a new repository... exclude_meta.type: [test] strips every
   `meta.type: test` entry **from the package**" wording in
   `docs/kickside-development/15-publishing.md` (which reads as
   publish-time-only). Given this, the 5 colocated logic tests in this
   module (`output_test`, `data_error_test`, `transport_test`,
   `discover_resources_test`, `pull_core_test`) live in `test/src/`
   (importing the production entries by id via `imports:`), exactly
   matching the shape the *original* template's own `test/src/log_test.lua`
   already used — not colocated next to `client/output.lua` etc. as
   `docs/kickside-development/12-module-layout.md`/`13-testing.md`'s more
   generic wording would suggest. If this repo's real Hub-side deployment
   handles `exclude_meta` differently than a local standalone harness (e.g.
   a live app's registry sync ignoring it, unlike this local workspace
   replacement), that would reconcile the doc wording — untested here, no
   live Kickside host was available.
3. Wiring the full transitive requirement graph for `kickside/connection` +
   `kickside/component` in the standalone harness pulled in a surprisingly
   large chunk of the platform — `kickside/core`, `kickside/uploads`,
   `kickside/jobs`, `wippy/session`, `wippy/llm`, `wippy/views`,
   `wippy/migration` — none of which this connector actually uses at
   runtime. Every `ns.requirement` those transitively-installed modules
   declare had to be wired through `test/src/_index.yaml`'s bootloader
   `parameters` (api_router/process_host/target_db/env_storage/
   user_security_scope, following the standard convention table in
   `docs/kickside-development/16-conventions.md`) before `wippy test` would
   boot at all — including one requirement, `kickside.core.projections:
   env_storage`, that additionally needed an actual `app.env:store`
   resource to exist (`test/src/env/_index.yaml`), since
   `kickside.core`'s own `env.variable` entries reference that id directly
   per the "Idiom A" pattern in `16-conventions.md`, not through a further
   requirement indirection. All of this is harness-only wiring with no
   effect on the module's actual published behavior.

## Not exercised end-to-end against a live host

Per `docs/kickside-development/13-testing.md`'s "Harness Limits" — the
standalone harness cannot open contracts under an actor/scope. This means
`test_connection`, `discover_resources`, `get_status`, `delete`, `pull`, and
`pull_keys`'s actual contract-dispatched behavior (credential resolution via
`component.get_private_context`, `ctx.get("component_id")` inside a real
open) was **not** exercised end-to-end — only their pure logic (REST
pagination, item/key normalization, credential-mode branching, redaction,
error mapping) is unit-tested, and their registry wiring (correct contract
binding, correct method map, correct automation port shape) is verified via
`wiring_test.lua`. No live, source-free Kickside host was available during
this build to run the end-to-end exercise
`docs/kickside-development/13-testing.md` calls for on success paths a
standalone harness cannot represent. Whoever next has access to a live host
should run a real Connect flow (app password and access token modes both)
against a real Bitbucket workspace before considering this module fully
proven.
