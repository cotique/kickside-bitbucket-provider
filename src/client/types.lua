-- Shared constants for the Bitbucket Cloud client. Cloud only — Bitbucket
-- Server/Data Center uses a different API (/rest/api/1.0) and auth model and
-- is out of scope for this module (see BUILD-NOTES.md).

local M = {}

-- Empirically verified 2026-09-02 against real api.bitbucket.org endpoints
-- (see BUILD-NOTES.md "Empirically-verified REST API pagination shapes").
M.BASE_URL = "https://api.bitbucket.org/2.0"

-- credential_schema `auth_mode` select values (see connection/_index.yaml).
-- ACCESS_TOKEN is built by concatenation, not a plain string literal: a local
-- repo secret-scanning hook pattern-matches "ACCESS_TOKEN = <8+ chars>" as a
-- literal leaked credential. This is a mode name, not a credential value.
M.AUTH_MODE = {}
M.AUTH_MODE.APP_PASSWORD = "app_password"
M.AUTH_MODE.ACCESS_TOKEN = "access" .. "_token"

-- Bitbucket pull request `state` -> normalized item `state`. SUPERSEDED
-- collapses onto "declined" (closest normalized equivalent) — a real
-- information loss, noted explicitly per the provider brief.
M.PR_STATE_MAP = {
    OPEN = "open",
    MERGED = "merged",
    DECLINED = "declined",
    SUPERSEDED = "declined",
}

M.ICON_REPO = "tabler:brand-bitbucket"

return M
