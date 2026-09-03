# Cotique Bitbucket

Read-only Bitbucket Cloud connector for Kickside.

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

## Planes

- **B — source flows**: `repo_pulls` pulls a selected repository's pull
  requests on a schedule through Kickside Data Sync. Cursor-based,
  continuous — each `pull()` call returns a resumable cursor even once
  exhausted, so the same port keeps picking up new activity indefinitely.
  Keys-only reconcile (for Data Sync's own drift detection) is wired through
  the port's `reconcile.pull_keys` field, not a second `kickside.data:
  pullable` method — that contract binds exactly one, `pull`.

Read-only, always: no create/comment/approve/merge method exists anywhere in
this module. Scope is Bitbucket Cloud only — Server/Data Center is a
different API and auth model, out of scope here.
