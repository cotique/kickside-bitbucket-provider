# Bitbucket Connector

Bitbucket Cloud connector for Kickside: a read-only Data Sync pull-request
source, plus agent-tool traits for limited interactive pull-request
read/write access.

## Auth

One credential mode: a repository access token. Bitbucket Cloud app
passwords are fully deprecated (removal completed 2026-07-28), so this is
the only supported mode. A repository access token is scoped to exactly one
repository and cannot reach any account-wide endpoint — so the connection
itself is scoped to one repository too: `workspace` + `repo_slug` identify
which one, alongside the token. Secrets live in the connection component's
`private_context`.

## Layout

- `client/` — low-level REST client (`api.lua`), auth + transport
  (`transport.lua`), shared types, safe output encoding (credential
  redaction), and the DataError mapping every failure path returns through.
- `connection/` — the `kickside.connection:connection` binding
  (`bitbucket_connection`): `test_connection` and `discover_resources` both
  call this repository's own endpoint, never an account-wide one.
- `source/` — the pull-request source: `pull_core.lua` (pagination, item
  normalization — the tested, provider-specific logic) plus the
  `kickside.data:pullable` binding (`repo_pulls_source`) and its
  `kickside.automation.port` (`repo_pulls`).
- `traits/` — agent-tool traits (`reader`/`writer`/`manager`) giving an
  LLM/agent interactive access to the connected repository's pull requests,
  distinct from the Data Sync source above: `read_tool` (list/get pull
  requests and their comments) and `write_tool` (create/update/decline a
  pull request, comment on one). Mirrors `kickside.github.traits:*`'s shape
  and restraint.

## Planes

- **B — source flows**: `repo_pulls` pulls a selected repository's pull
  requests on a schedule through Kickside Data Sync. Cursor-based,
  continuous — each `pull()` call returns a resumable cursor even once
  exhausted, so the same port keeps picking up new activity indefinitely.
  Keys-only reconcile (for Data Sync's own drift detection) is wired through
  the port's `reconcile.pull_keys` field, not a second `kickside.data:
  pullable` method — that contract binds exactly one, `pull`.
- **Agent tools**: `cotique.bitbucket.traits:reader`/`:writer`/`:manager`
  give an agent capability picked via a connection trait context
  (`connection_id`, scoped to that one repository), not a schedule. The
  writer trait is deliberately narrow — create/update/decline a pull
  request, comment on one — and never merges, approves, deletes, or reaches
  repository files, branches, releases, settings, collaborators, or
  pipelines, matching `kickside.github.traits:writer`'s own restraint.

The Data Sync source (`source/`) is, and stays, read-only: no create/comment/
approve/merge method exists there. Write capability exists only through the
`traits/` agent tools described above, and only for the three pull-request
actions listed. Scope is Bitbucket Cloud only — Server/Data Center is a
different API and auth model, out of scope here.
