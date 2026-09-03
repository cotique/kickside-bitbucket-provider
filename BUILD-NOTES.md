# Build notes — cotique/bitbucket

This module is a Bitbucket Cloud connector for the Kickside platform: a
`kickside.connection` provider (access token only — see the 2026-09-02
entry below for why app passwords were removed) plus a
`kickside.data:pullable` source publishing a selected repository's pull
requests as an automation port. Read alongside `README.md` and
`AGENTS.md`.

## Deliverable checklist

- [x] `wippy.yaml` — `description` rewritten from the template's log-sink
      placeholder; `repository:` fixed from the template's guessed
      `https://github.com/cotique/bitbucket` to the real
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
                              colocated logic tests (see item 2 under "Harness-wiring
                              findings" below for why they live here rather than next
                              to their source)
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

Moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "`kickside.data:pullable`
contract: real item/cursor envelope shape, and how `pull_keys` reconciliation
is wired." Any module implementing a Data Sync pullable source hits the
identical envelope requirements (item wrapping, table-shaped cursor, the
real DataError taxonomy); none of it was specific to Bitbucket, and this
was the correction of an earlier, inference-only guess once real reference
source (`kickside/github`, `kickside/atlassian`'s `jira`) became available.
This module's own implementation lives in `source/pull_core.lua`, and its
`client/data_error.lua` follows the real taxonomy the shared entry
documents.

## RESOLVED: `pull_keys` reconcile wiring

Moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "`kickside.data:pullable`
contract: real item/cursor envelope shape, and how `pull_keys` reconciliation
is wired" (same entry as above). This module's own `reconcile:` wiring lives
in `source/_index.yaml`'s `repo_pulls` entry, pointing at `source/pull.lua`'s
`pull_keys` export.

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

The general finding — bare `wippy lint` checks the whole resolved
dependency graph, not just this module's own code, and the
currently-published `kickside/core@0.1.94` has a confirmed real upstream
type error inside `kickside.core.projections.persist:catchup` — was already
in the shared platform findings file before this session
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`, "`wippy lint` (bare) checks
the whole resolved dependency graph, not just your module — and
`kickside/core` has a confirmed real upstream type error"). Nothing here
needed to move; this section just cross-references it. This module hit the
identical bug — confirmed via the same 3 errors, all inside
`kickside.core.projections.persist:catchup` — because implementing the
mandated `kickside.connection:connection` provider pattern (which requires
`kickside/connection` and, via `component.get_private_context`,
`kickside/component`) transitively pulls `kickside/core@0.1.94` in.

**Fix applied here, matching the shared entry's own recommendation:**
scoped the Makefile's `lint` target to this module's own namespace —
`wippy lint --ns "cotique.bitbucket.*"` (a `LINT_NS` var). Re-verified after
the fix: `wippy lint --ns "cotique.bitbucket.*"` → `No issues found`, and
`make verify` passes end to end (see the "Deliverable checklist" above for
the current test count). Re-run bare `wippy lint` after any future
`kickside/core` upgrade to check whether the upstream bug has been fixed —
if so, the Makefile scoping can be relaxed back to unscoped, though there's
no urgency to do so.

## Harness-wiring findings (useful for the next module built from this template)

Three platform quirks were hit and worked around while wiring the
standalone test harness. Two are genuinely platform-wide and moved to the
shared findings file; the third stays here since it's this module's own
specific transitive-dependency wiring list, not new platform knowledge
beyond what's already documented there.

1. **`wippy update`'s workspace-replacement scanning needs a pre-existing
   lock file to activate.** Moved to the shared platform findings file
   (`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see the addendum on
   "The standalone test harness (`test/`, from the `wippyai/kickside-module`
   template) has real, undiscovered gaps in component/KB wiring." Fixed
   here by having `Makefile`'s `setup:` target run `cd test && wippy
   update` (bare) immediately followed by `cd test && wippy update
   --config .wippy.yaml`.
2. **`wippy.yaml`'s `exclude_meta.type: [test]` is applied even through a
   `workspace.replacements` load, not just at publish time.** Moved to the
   shared platform findings file — see "`wippy.yaml`'s `exclude_meta.type:
   [test]` is applied even through a `workspace.replacements` load, not
   just at publish time." Given this, the 5 colocated logic tests in this
   module (`output_test`, `data_error_test`, `transport_test`,
   `discover_resources_test`, `pull_core_test`) live in `test/src/`
   (importing the production entries by id via `imports:`) rather than
   colocated next to their source files.
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
   effect on the module's actual published behavior. (The general lesson —
   budget for a new dependency's full transitive closure, not just the
   package named — is already in the shared findings file's own "Best
   practices" list.)

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

## Structural audit against the real reference modules (2026-09-02)

With `providers-master\providers-master\atlassian` and `...\github` available
locally, did a full file-by-file structural comparison beyond the
`kickside.data:pullable` envelope (already covered above). Checked and
confirmed fine, no change needed:

- No `client/site.lua`-style base-URL/tenant resolution needed — Bitbucket
  Cloud has no equivalent multi-tenant indirection to resolve.
- Agent-tool traits (`jira/traits`, `confluence/traits`, `github/traits`) —
  confirmed still correctly out of scope (see "Deliberate scope decisions"
  above).
- `kickside.data:writable` sinks (real Atlassian can also *write* issues/
  pages via Data Sync, `jira/sink`, `confluence/sink`) — confirmed correctly
  absent here; this module is read-only per eng-metrics SPEC.md decision B0,
  not an oversight.
- **Dependency set.** Confirmed this module's `src/_index.yaml` already
  matches the real, minimal provider-module dependency set — moved to the
  shared platform findings file
  (`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "A credential-only,
  no-picker connection provider needs no `ui/`, `api/`, or `security/`
  folder, no `embed:`, and no `kickside/core` dependency." Its sibling
  module, `kickside-gitlab-provider`, had picked up an unnecessary explicit
  `kickside/core` dependency from a flawed earlier experiment and has since
  been corrected to match this module's already-correct shape — see that
  repo's own BUILD-NOTES.md.

Found and fixed:

- **`wippy.yaml` was missing the top-level `type: plugin` field.** Moved to
  the shared platform findings file — see "`wippy.yaml` needs a top-level
  `type: plugin` field — every real provider module declares it." Added
  here.

Flagged, not changed (a real decision, not a technical correctness issue):

- **License.** Every real provider module in the reference monorepo uses
  `BUSL-1.1`; this module still has the template's default `MIT`. Left
  as-is — which license this repo ships under is the user's call, not
  something to silently match to Wippy's own platform-module convention.

## RESOLVED: removed the UI/api/security apparatus, which also fixed a real fresh-checkout bootstrap deadlock

The general precedent behind this change — that a credential-only,
no-picker connection provider needs no `ui/`, `api/`, or `security/` folder
and no `embed:` at all, matching `discord`/`slack`/`telegram`/`sso-*` in the
real reference monorepo — moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "A credential-only,
no-picker connection provider needs no `ui/`, `api/`, or `security/`
folder, no `embed:`, and no `kickside/core` dependency." This module's own
`src/api/` (a custom `GET /bitbucket-provider/status` endpoint),
`src/security/` (the policy gating that endpoint), and the entire `ui/`
(status Vue page) + `static/` (its built bundle) were template-demo
leftovers, adapted rather than removed in the initial build pass.

**Removed:** `src/api/`, `src/security/`, `ui/`, `static/`; the
`api_router`/`ui_server` `ns.requirement`s and `ui_fs`/`ui_static`/
`bitbucket_provider_view`/`nav_item` entries from `src/_index.yaml`; the
`embed:` block from `wippy.yaml`; the `build`/`typecheck`/`dev` Makefile
targets and `EMBED` var; the corresponding assertions in
`test/src/wiring_test.lua`. Patched `scripts/check-module.mjs` (previously
unconditionally read `ui/package.json`/`ui/vite.config.ts`/
`ui/src/styles.css`) to gate every frontend-contract check behind `const
hasUi = await exists(resolve(root, 'ui/package.json'))`.

**Unexpected, real bonus:** removing `src/security/` also fixed a genuine
fresh-checkout bootstrap deadlock. Full writeup moved to the shared
platform findings file — see the addendum on "CI: a raw `.wippy.yaml`
override targeting a workspace-replaced module's entry stopped resolving in
wippy runtime v0.3.35a." In short: `bdf0085`'s own "Fix CI" commit had
declared the module-under-test itself as an explicit `ns.dependency`
(`bitbucket_provider_harness.dep.module`) purely to route its own
`user_security_scope` requirement through `parameters:` instead of a raw
`.wippy.yaml` `override:` path that had stopped resolving under the current
CLI — but that self-dependency meant `wippy update`'s first pass always
tried (and failed) to resolve the never-published module directly against
the Hub, writing no lock at all and permanently starving the documented
two-pass bootstrap trick. Removing `src/security/` here removes the only
reason `bitbucket_provider_harness.dep.module` existed — with it gone, the
harness surfaces the module purely through `test/.wippy.yaml`'s
`workspace.replacements`, confirmed to bootstrap cleanly from a genuinely
fresh checkout.

`make verify` re-run clean after all of this, from a directory with `test/
.wippy/vendor`, `test/wippy.lock`, and the root `wippy.lock` all deleted
first (i.e. a real fresh-checkout simulation, not just "still had a stale
lock lying around"): 49/49 tests on both SQLite and Postgres (shared
`wippy-postgres` instance, port 5432), lint clean, no build/typecheck step
needed anymore.

## RESOLVED: CI red — a real `wippy test` regression in v0.3.35a, not our fix

Full writeup (symptom, isolation method, and confirmation this reproduces
identically on a second, independent repo) moved to the shared platform
findings file (`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "A
third, distinct `wippy` runtime v0.3.35a+ regression: a workspace-replaced
module's own entries are not found during `wippy test`'s state-loading."
This is the third distinct `v0.3.35a+`-era regression this project's own
history has hit around workspace-replaced modules (the first two: the raw
`.wippy.yaml` `override:` path `bdf0085` worked around, and the
explicit-module-dependency bootstrap deadlock that working around it
introduced — see the "RESOLVED: removed the UI/api/security apparatus"
section above).

**Fix:** pinned `WIPPY_VERSION: v0.3.33a` in `.github/workflows/verify.yml`
instead of `latest`, per that file's own stated policy ("set an exact tag
only to bisect a runtime regression" — this is exactly that case). Not a
permanent fix — revert to `latest` once a release without this regression
ships, or re-pin/bisect again if it recurs.

## Renamed module identity: cotique/bitbucket-provider -> cotique/bitbucket (2026-09-03)

Matching the real reference convention (`kickside/github`, `kickside/
atlassian`, `kickside/discord` etc. don't carry a `-provider`/`-connector`
suffix on the module name itself) — the same rename already applied to the
sibling `kickside-gitlab-provider` repo. Renamed throughout: `wippy.yaml`
(`module:`, keywords), `.kickside-module.json` identity, the root namespace
(`cotique.bitbucket_provider` -> `cotique.bitbucket`), the test harness's
workspace replacement target and Postgres database name
(`cotique_test_bitbucket_provider` -> `cotique_test_bitbucket`), and the CI
workflow. The GitHub repository URL in `wippy.yaml` (`repository:
https://github.com/cotique/kickside-bitbucket-provider`) is deliberately
untouched — that identifier is independent of the Wippy module identity.

Done the same way as the gitlab-provider rename: a scripted,
compound-token-first pass (longest/most specific tokens first) followed by
a manual pass for the remaining bare occurrences, specifically to avoid
corrupting `kickside-bitbucket-provider` (the real GitHub repo name, which
contains `bitbucket-provider` as a substring) with a blind global replace.
