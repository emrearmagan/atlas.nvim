# Gitea/Forgejo Provider Design

**Date:** 2026-06-13  
**Scope:** Issues + Pulls providers for Gitea/Forgejo via `tea` CLI

---

## Context

atlas.nvim already has GitHub (gh CLI + GraphQL), GitLab (curl + REST), Bitbucket (curl + REST), Jira (curl + REST).

Gitea/Forgejo support via `tea` CLI. Key insight: `tea api <endpoint>` is authenticated HTTP proxy — identical pattern to `gh api`, but Gitea exposes only REST (no GraphQL). `tea` reads auth and base URL from its own config (`~/.config/tea/config.yml`) which is populated by `tea login`. No extra credentials in atlas config required.

---

## Transport Layer

`tea api <endpoint>` wraps Gitea REST API v1. Auth is transparent — `tea` reads the token from its login config matched to the git remote URL. Pagination via `--limit` and `--page` query params (no `--paginate` flag like `gh`).

Both issues and pulls share one `api/cli.lua` per domain:

```lua
-- tea api repos/{owner}/{repo}/issues?state=open&limit=30&page=1
M.tea(args, callback, ctx)        -- raw call, JSON-decoded response
M.api(method, endpoint, body, callback, ctx)  -- tea api -X METHOD endpoint
```

No `--json` flag (Gitea REST always returns JSON). Pagination handled by the caller — append `?limit=N&page=N` to endpoint.

---

## Issues Provider

### Files

| File | Lines | Purpose |
|------|-------|---------|
| `api/cli.lua` | ~40 | `tea` wrapper, cache helpers |
| `api/mapper.lua` | ~30 | Thin patch: `raw.user` → author, `full_name` from `repository`, REST reactions |
| `api/issues.lua` | ~150 | `search_issues`, `get_issue`, `set_state`, `create_issue` |
| `api/comments.lua` | ~80 | list, add, edit, delete |
| `api/users.lua` | ~25 | `tea whoami -o json` |
| `api/timeline.lua` | ~80 | Gitea issue events → `IssueActivityEntry[]` |
| `config.lua` | ~20 | `AtlasGiteaIssuesConfig` type |
| `highlights.lua` | ~15 | Copy GitHub highlights |
| `init.lua` | ~120 | Implements `IssuesProvider` |

### REST Endpoints Used

```
GET  repos/{owner}/{repo}/issues?type=issues&state=open&assigned=true&limit=N&page=N
GET  repos/{owner}/{repo}/issues/{index}
GET  repos/{owner}/{repo}/issues/{index}/comments
POST repos/{owner}/{repo}/issues/{index}/comments      body: {body}
PATCH repos/{owner}/{repo}/issues/comments/{id}        body: {body}
DELETE repos/{owner}/{repo}/issues/comments/{id}
POST repos/{owner}/{repo}/issues/{index}/reactions     body: {content}
GET  repos/{owner}/{repo}/issues/{index}/timeline
PATCH repos/{owner}/{repo}/issues/{index}              body: {state}
POST repos/{owner}/{repo}/issues                       body: {title, body, ...}
GET  repos/{owner}/{repo}/labels?limit=50
GET  repos/{owner}/{repo}/milestones?state=open&limit=50
GET  user                                              (whoami)
GET  notifications?all=true&limit=100
PATCH notifications/threads/{id}                       (mark read)
```

### Views Config

Views use a `filter` table that maps to Gitea query params:

```lua
gitea = {
  views = {
    { name = "Assigned", key = "1", filter = { assigned = true, state = "open" } },
    { name = "Created",  key = "2", filter = { created  = true, state = "open" } },
    { name = "All Open", key = "3", filter = { state = "open" } },
    { name = "All",      key = "4", filter = { state = "all"  } },
  }
}
```

Default (no views configured): single "Assigned" view.

### Mapper Differences vs GitHub

GitHub mapper already handles REST field names (`created_at`, `html_url`, `full_name`). Gitea-specific patches:

- `raw.user` → author (GitHub uses `raw.author` from GraphQL; REST uses `raw.user`)
- Reactions: Gitea REST `/reactions` returns `[{user, content}]` — aggregate by `content` to `{"+1": N, ...}`
- Timeline events: Gitea uses same event names as GitHub REST (`labeled`, `assigned`, `closed`, etc.) — can reuse `to_timeline_entry` with minor additions

---

## Pulls Provider

### Files

| File | Lines | Purpose |
|------|-------|---------|
| `api/cli.lua` | ~40 | Same pattern as issues cli.lua |
| `api/mapper.lua` | ~80 | `to_pull_request`, `to_comment`, `to_review_comment` |
| `api/pullrequests.lua` | ~120 | list, get, merge, set_state |
| `api/comments.lua` | ~80 | PR comments + inline review comments |
| `api/commits.lua` | ~40 | PR commits list |
| `api/checks.lua` | ~50 | CI statuses via `/statuses/{sha}` |
| `api/notifications.lua` | ~30 | Delegates to issues notifications |
| `config.lua` | ~20 | `AtlasGiteaPullsConfig` type |
| `highlights.lua` | ~15 | Copy GitHub highlights |
| `init.lua` | ~180 | Implements `PullsProvider` |
| `ui/panel.lua` | ~80 | PR panel tabs config |

### REST Endpoints Used

```
GET  repos/{owner}/{repo}/pulls?state=open&limit=N&page=N
GET  repos/{owner}/{repo}/pulls/{index}
GET  repos/{owner}/{repo}/pulls/{index}/files
GET  repos/{owner}/{repo}/pulls/{index}/commits
GET  repos/{owner}/{repo}/pulls/{index}/reviews
GET  repos/{owner}/{repo}/pulls/{index}/comments   (review/inline comments)
POST repos/{owner}/{repo}/pulls/{index}/comments   body: {body, path, line}
GET  repos/{owner}/{repo}/issues/{index}/comments  (PR general comments — same endpoint)
POST repos/{owner}/{repo}/issues/{index}/comments  body: {body}
GET  repos/{owner}/{repo}/statuses/{sha}           (CI status)
GET  repos/{owner}/{repo}/branches?limit=50
GET  repos/{owner}/{repo}/tags?limit=50
DELETE repos/{owner}/{repo}/branches/{branch}
```

### State Mapping

```
Gitea state + merged field → atlas state
open  + draft=true   → "draft"
open  + draft=false  → "open"
closed + merged=true → "merged"
closed + merged=false → "declined"
```

### PR Mapper Key Differences vs GitHub

- `raw.user` not `raw.author`
- `raw.draft` not `raw.isDraft`  
- `raw.merged` boolean (explicit), not inferred from state
- No `reviewDecision` field — derive from reviews list
- `repository.full_name` not `repository.nameWithOwner`
- CI: no `statusCheckRollup` in PR body — fetch separately from `/statuses/{sha}`

---

## Changes to Existing Files

### `lua/atlas/init.lua`

Add `"gitea"` to:
- `configured_provider_ids` order arrays (both domains)  
- `load_pulls_provider` and `load_issues_provider` switch cases

### `lua/atlas/config.lua`

Add:
- `AtlasGiteaIssuesConfig` and `AtlasGiteaPullsConfig` type annotations
- `"gitea"` to `AtlasPullsProviderId` and `AtlasIssuesProviderId` aliases
- `gitea` field in `AtlasPullsProviders` and `AtlasIssuesProviders`

### `lua/atlas/health.lua`

Add `check_gitea()`:
- Check `tea` executable present
- Run `tea whoami` to verify auth
- Report configured views count

---

## What Is NOT Implemented

- Reactions (Gitea reactions API returned `null` in testing — defer until confirmed working instance)
- Sub-issues (Gitea has no sub-issue concept)
- PR review submit (approve/reject) — read-only review display only
- `viewerSubscription` (no equivalent in Gitea API)

---

## User Config Example

```lua
require("atlas").setup({
  issues = {
    providers = {
      gitea = {
        views = {
          { name = "Assigned", key = "1", filter = { assigned = true, state = "open" } },
          { name = "Created",  key = "2", filter = { created  = true, state = "open" } },
          { name = "All Open", key = "3", filter = { state = "open" } },
        },
      },
    },
  },
  pulls = {
    providers = {
      gitea = {},
    },
    repo_config = {
      paths = { ["/path/to/repo"] = "owner/repo" },
    },
    diff = { open_cmd = "DiffviewOpen" },
  },
})
```

Auth is handled by `tea login` — no token in atlas config.
