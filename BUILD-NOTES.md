# Build notes — cotique/bitbucket-provider

This module is a Bitbucket Cloud connector for the Kickside platform: a
`kickside.connection` provider (access token only — see the 2026-09-02
entry below for why app passwords were removed) plus a
`kickside.data:pullable` source publishing a selected repository's pull
requests as an automation port. Read alongside `README.md` and
`AGENTS.md`.

## Deliverable checklist

- [x] `wippy.yaml` — `description` rewritten from the template's log-sink
      placeholder; `repository:` fixed from the template's guessed
      `https://github.com/cotique/bitbucket-provider` to the real
      `https://github.com/cotique/kickside-bitbucket-provider`.
- [x] `src/` implements the connection + source structure below.
- [x] `test/` — colocated-logic tests + harness registry-shape test +
      the real `pullable_conformance` kit, `make verify` passes clean end
      to end (56/56 tests on SQLite, re-verified after the
      `kickside.data:pullable` envelope correction pass — see "RESOLVED:
      `kickside.data:pullable` request/response shape" above).
      Postgres confirmed too: `test/.wippy.yaml`'s default port 5433 was
      occupied by an unrelated `job-search-ai-postgres-1` container from a
      different local project, so instead of stopping someone else's
      container, the already-running shared `wippy-postgres` instance on the
      default port 5432 was reused (same convention `cotique/eng-metrics`'
      own BUILD-NOTES documents) — `wippy test --profile postgres --set
      vars.pg_port=5432` from `test/`, 56/56 passing, confirming parity with
      the SQLite result above. No repo changes needed; `compose.test.yaml`'s
      own port-5433 default stays correct for CI/other developers.
      See "RESOLVED: pre-existing lint errors
      in a transitive platform dependency" below for the earlier Makefile fix this
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
    pull_core.lua            fetch_page/list_all/normalize_item/normalize_key plus the
                              confirmed kickside.data:pullable envelope (pull/pull_keys)
    pull.lua                 pull()/pull_keys() — thin pass-through to pull_core
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
  matching eng-metrics SPEC.md decision B0. The credential field's `help`
  text tells the user to scope the access token to
  `Repositories: Read` + `Pull requests: Read` only.

## RESOLVED: `kickside.data:pullable` request/response shape

**Fully resolved in a follow-up pass.** Real, unpacked source for
`git.wippy.ai/kickside/providers` became available locally at
`providers-master\providers-master\` (outside this repo). The envelope
previously inferred by analogy below has been read directly against two
real implementations of this exact contract and corrected where it was
wrong:

- `providers-master\providers-master\github\src\source\pull_core.lua`
- `providers-master\providers-master\atlassian\src\jira\source\pull_core.lua`
- `providers-master\providers-master\github\src\source\_index.yaml`
- `providers-master\providers-master\github\src\client\data_error.lua`
- `providers-master\providers-master\github\src\source\pull_core_test.lua`
- `providers-master\providers-master\atlassian\src\jira\source\pull_core_test.lua`
- `providers-master\providers-master\atlassian\test\pullable_conformance.lua`
  and `...\atlassian\test\_index.yaml`

Confirmed wrong and fixed, concretely:

1. **Items were flat, must be wrapped.** Every pulled item is now
   `{ item_key, dedup_key, op = "upsert", source_version, occurred_at,
   payload = <normalized item> }`, not the bare normalized item this module
   previously returned directly. See `source/pull_core.lua`'s
   `M.normalize_item`/`M.normalize_key`.
2. **Cursor must be a table, never a bare string, and never nil on
   success.** `source/pull_core.lua`'s `M.pull`/`M.pull_keys` now wrap
   Bitbucket's own literal `next` URL as `{ next_url = <string|nil> }`.
   `next_cursor` is set on every successful response — on exhaustion it
   resets to `{ next_url = nil }` (start over from page 1) instead of going
   nil, matching both real examples' "reset to a fresh resumable position
   so a scheduler can keep polling forever" behavior. This connector does
   not yet honor `backfill_since` as a continuation filter (no verified
   Bitbucket query filter for it — resetting to page 1 means a full rescan
   each cycle, a real but disclosed inefficiency, not a silent gap); the
   conformance test below declares this explicitly
   (`backfill_since = { mode = "ignored", reason = ... }`).
3. **`url` renamed to `source_url`** in the payload, matching the platform
   convention confirmed in both real reference files
   (`source/_index.yaml`'s `output_schema` updated to match).
4. **`client/data_error.lua` rewritten** to the real taxonomy from
   `providers-master\providers-master\github\src\client\data_error.lua`:
   same function names (`M.failure`/`M.connection`/`M.invalid_config`/
   `M.from_result`), same full pullable-envelope return shape, same code
   vocabulary (`auth_expired`, `invalid_config`, `permission_denied`,
   `not_found`, `rate_limited`, `provider_unavailable`, `provider_error`),
   replacing the previously-inferred vocabulary
   (`auth_failed`/`forbidden`/`unknown_error`/`invalid_request`). One
   deliberate deviation, documented in the file itself: `client/api.lua`
   (out of scope for this fix, independently confirmed correct) follows a
   `(decoded, err)` two-value Lua convention where `err` is a *bare*
   `{code,message,retriable,scope}` record, not a `{success=false,
   error=...}` envelope — `connection/test_connection.lua` and
   `connection/discover_resources.lua` (also out of scope) read
   `err.message` directly off that bare record and must keep working
   unchanged. `M.new`/`M.from_http`/`M.from_transport` are kept, under
   their original names, as this connector's own bare-record builders
   (`M.new(...)` is exactly `M.failure(...).error`) so `client/api.lua`
   needed zero call-site changes; `source/pull_core.lua`'s `M.pull`/
   `M.pull_keys` use the real `M.connection`/`M.invalid_config`/
   `M.from_result` functions directly and return their result AS the
   pullable envelope response, exactly like the real github/jira
   `pull_core.lua`.
5. **`pull_keys` reconcile wiring found.** See "RESOLVED: `pull_keys`
   reconcile wiring" below — this was the one open question the previous
   pass genuinely couldn't answer without real source.
6. **Conformance test kit added.** `test/src/pullable_conformance.lua` is a
   verbatim copy of
   `providers-master\providers-master\atlassian\test\pullable_conformance.lua`
   (a generic, provider-agnostic checker — not adapted), registered in
   `test/src/_index.yaml` exactly like `...\atlassian\test\_index.yaml`
   does. `test/src/pull_core_test.lua`'s "passes the pullable conformance
   kit offline" case calls `registry.get("kickside.data:pullable")` at test
   time to validate this connector's actual `pull`/`pull_keys` output
   against the real, live JSON schema — the definitive check, not
   inspection-by-analogy. It passes (see `make test`/`make test-pg` output).
7. **`component_id` resolution fallback chain added.** `source/pull_core.lua`'s
   `resolve()` now tries `deps.component_id` -> `ctx.get("component_id")` ->
   `config.connection_id`, matching both real reference `pull_core.lua`
   files exactly (previously this module only tried `ctx.get`).
8. **`config_schema.connection_id` added** to the `repo_pulls` automation
   port, matching the real `kickside.github.source:repo_items` port's
   `connection_id` field shape (`kickside-connection-trait-picker`,
   `role: primary`, `required: true`, `provider: bitbucket`).

Below is the original build's account of what was confirmed and still
inferred at the time, kept for the historical record.

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
  **No longer open — see "RESOLVED: `pull_keys` reconcile wiring" below:**
  Data Sync's reconcile path reaches a keys-only listing via a `reconcile:`
  field sibling to `binding:` on the `kickside.automation.port` registry
  entry (`repo_pulls` in `source/_index.yaml`), confirmed against the real
  `providers-master\providers-master\github\src\source\_index.yaml`.
  `kickside.data:data_connector_manifest_schema` (a JSON-Schema
  `registry.entry`, visible even though the module is packed — its
  `meta.json_schema` is plain data, not Lua) describes a *different*,
  consolidated "data.connector" manifest shape (`connection`/`sources`/
  `sinks`/`tools` all under one entry) that `kickside/github` does **not**
  use (its registry has no such entry). It may be a newer/alternative
  registration path for a different family of connectors; it does not
  resolve the `pull_keys` question and was not adopted here since
  `kickside/github` itself doesn't use it.
- **No longer inferred — CONFIRMED, see "RESOLVED: `kickside.data:pullable`
  request/response shape" above.** The envelope described in this bullet
  (`{ config, cursor }` request; flat-item success shape; bare-error
  failure shape) was the inference that turned out to need three concrete
  corrections once real source became available: items must be wrapped
  (`item_key`/`dedup_key`/`op`/`source_version`/`occurred_at`/`payload`),
  the cursor must be a table that's never nil on success, and the failure
  shape needed to come from a real DataError taxonomy, not a
  `writable.write`-shaped guess. This bullet is kept for the historical
  record of what was inferred and why (analogy to `kickside.data:writable.write`,
  the template's own `src/sink/write.lua`) — it is not current.
- **What resolved it:** real, unpacked source for
  `git.wippy.ai/kickside/providers` became available locally (see the
  "RESOLVED" section above for exact paths) — the eng-metrics precedent
  this brief originally pointed at, now actually reachable.
- **No longer split the way this bullet describes.** `pull_core.lua` now
  owns the confirmed envelope directly (`M.pull`/`M.pull_keys`), matching
  both real reference `pull_core.lua` files — it depends on the envelope
  deliberately now that the envelope is confirmed, not inferred.
  `source/pull.lua` is a thin pass-through to `pull_core.pull`/
  `pull_core.pull_keys`. `test/src/pull_core_test.lua` now also carries the
  real `pullable_conformance` kit's offline pass (see above).

## RESOLVED: `pull_keys` reconcile wiring

Confirmed against the real
`providers-master\providers-master\github\src\source\_index.yaml`: the
`kickside.automation.port` registry entry (`repo_pulls` here) carries a
`reconcile:` field, a sibling to `binding:`, not a second bound method
under the `kickside.data:pullable` contract (that contract accepts exactly
one bound method, `pull` — see above, this finding was already correct).
Shape:

```yaml
reconcile:
  pull_keys: cotique.bitbucket_provider.source:pull_keys
```

`source/_index.yaml`'s `repo_pulls` entry now carries this field, pointing
at the same `pull_keys` function.lua entry that was previously registered
but structurally unreachable. `pull_keys` is not dead code.

## RESOLVED (moot): `required_if` credential_schema syntax

**Resolved by removal, not by verification, in the 2026-09-02 entry below.**
The `required_if` usage this section describes existed only to make
`username`/`app_password` conditionally required when `auth_mode ==
app_password`. That whole mode was deleted from `credential_schema` (app
passwords are fully deprecated on Bitbucket Cloud), leaving a single
required `access_token` field with no conditional-requirement logic at all.
There is nothing left in this module's `credential_schema` that needs
`required_if`, so the open question below is moot for this module — kept
verbatim for the historical record in case a future credential mode here
(or another module) needs conditional fields and wants to know this was
never independently confirmed.

Not independently verifiable at the time. Checked, in order:
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
  mode → `Authorization: Bearer <token>`. Both implemented in `client/api.lua`
  at the time of this finding. **Since the 2026-09-02 entry below, only the
  `access_token`/Bearer path is reachable from stored credentials** —
  `client/api.lua`'s `app_password`/Basic-auth branch is kept as a generic,
  unreachable capability of the low-level client (no credential_schema field
  or `transport.for_credentials` path produces `app_password` opts anymore),
  since removing it was out of scope for that change.
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
both SQLite and the shared Postgres instance — historical count at the time
of this fix; see the "Deliverable checklist" above for the current count
after the later `kickside.data:pullable` envelope correction pass added the
conformance test and expanded `pull_core_test.lua`/`data_error_test.lua`).
Re-run bare `wippy lint` after
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
should run a real Connect flow (access token mode — the only supported mode
since the 2026-09-02 entry below) against a real Bitbucket workspace before
considering this module fully proven.

## 2026-09-02: removed `app_password` credential mode — Bitbucket Cloud app passwords are deprecated and removed

**What changed.** `credential_schema` on `bitbucket_connection`
(`src/connection/_index.yaml`) no longer offers a two-mode `auth_mode`
select. The `auth_mode`, `username`, and `app_password` fields are gone;
the schema now has exactly one field, `access_token` (password-type,
required), with `help` text pointing at the real current navigation:
"Create one at a repository's own Settings > Security > Access tokens,
scoped to Repositories: Read and Pull requests: Read only." This mirrors
`cotique/gitlab-provider`'s single-field `gitlab_connection` credential_schema
shape (`token`, no `auth_mode`), since Bitbucket now genuinely has only one
supported credential mode, same as GitLab.

`src/client/transport.lua`'s `M.for_credentials` no longer branches on
`auth_mode`. It builds the client directly from `creds.access_token` via
`api.new({ auth_mode = types.AUTH_MODE.ACCESS_TOKEN, access_token = ... })`
— the `app_password`/Basic-auth branch (username + app_password) was
deleted from this function entirely. `client/api.lua`'s own lower-level
`app_password`/Basic-auth branch was left in place (out of scope for this
change; see the annotation added to "Empirically-verified findings" above)
since nothing in `transport.lua` can reach it anymore — it is now
unreachable dead capability of the generic low-level client, not a
user-facing credential mode.

Tests: `test/src/transport_test.lua`'s app_password-mode cases ("builds a
basic-auth client for app_password mode", "rejects app_password mode
missing the app_password field", "defaults to app_password mode when
auth_mode is not set") were removed — there is no `auth_mode` field left to
default, and no app_password branch left to test. The access_token-mode
case was kept and renamed ("builds a bearer-auth client for the stored
access token"); the "rejects access_token mode missing the access_token
field" case was kept (renamed "rejects credentials missing the access_token
field") and a new "rejects an empty access_token" case was added for parity
with the removed cases' coverage shape. The "rejects an unknown auth_mode"
case was removed — there is no `auth_mode` concept left in
`for_credentials` to reject.

`test/src/wiring_test.lua`'s "declares the Bitbucket connection provider
binding with a credential_schema" case asserted an `auth_mode` select field
existed; it now asserts an `access_token` field exists instead.

**Why.** Verified this session against Atlassian's own official docs (not
re-derived from training data):
- New Bitbucket Cloud app-password creation stopped 2025-09-09.
- Brownout period ran 2026-06-09 through 2026-07-27.
- Full removal completed 2026-07-28 (in the past as of today, 2026-09-02).
- <https://www.atlassian.com/blog/bitbucket/bitbucket-cloud-transitions-to-api-tokens-enhancing-security-with-app-password-deprecation>
- <https://www.atlassian.com/blog/bitbucket/bitbucket-cloud-enters-phase-2-of-app-password-deprecation>
- Replacement: repository- or workspace-scoped access tokens, created via a
  repository's own Settings > Security > Access tokens —
  <https://support.atlassian.com/bitbucket-cloud/docs/create-a-repository-access-token/>
  (current official docs, fetched and confirmed this session).

Offering `app_password` as a connect-form option was actively misleading:
nobody can create a new app password anymore, so a user picking that mode
would hit a dead end in Bitbucket's own UI, which no longer has an
app-password-creation page at all.

**Resolves, as moot:** the "RESOLVED (moot): `required_if` credential_schema
syntax" entry above — the only `required_if` usage in this module existed to
make `username`/`app_password` conditionally required under
`auth_mode: app_password`; that mode is gone, so there is nothing left in
this module needing `required_if`. See that entry for the full account.

**Verification:** `make verify` re-run clean end to end after this change —
setup, invariants, lint, typecheck, build, and the full SQLite test suite
all pass. See the repo's local commit for the exact test count.
