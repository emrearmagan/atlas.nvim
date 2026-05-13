--------------------------------------------------------------------------------
-- Main render result
--------------------------------------------------------------------------------

---@class PullsMainRenderResult
---@field lines string[]
---@field spans table[]
---@field line_map table<integer, table>

--------------------------------------------------------------------------------
-- Provider Interface
--------------------------------------------------------------------------------

---@class PullsFetchOpts
---@field force_load boolean|nil
---@field pagelen number|nil

---@class PullsProvider
---@field id string
---@field name string
---@field icon string
---@field hl_group string
---
--- Lifecycle:
---@field setup fun()|nil
---
--- Core data methods:
---@field fetch_user fun(on_done: fun(user: PullsUser|nil, err: string|nil))
---@field fetch_pullrequests fun(view: AtlasPullsViewConfig, opts: PullsFetchOpts, on_done: fun(groups: PullsGroup[], err: string[]|nil)): { cancel: fun() }|nil
---@field fetch_pullrequest fun(pr: PullRequest, opts: PullsFetchOpts, on_done: fun(pr: PullRequest|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_repo_details (fun(repo: PullsRepo, opts: PullsFetchOpts, on_done: fun(repo: PullsRepoDetails|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_repo_branches (fun(repo: PullsRepoDetails, opts: PullsFetchOpts, on_done: fun(branches: PullsRepoBranches|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_repo_tags (fun(repo: PullsRepoDetails, opts: PullsFetchOpts, on_done: fun(tags: PullsRepoTags|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_repo_branch (fun(repo: PullsRepoDetails, branch: PullsRepoBranch, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_description (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(description: string|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_reviewers (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(reviewers: PullsReviewer[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_builds (fun(pr: PullRequest, on_done: fun(builds: PullsBuild[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_merge_checks (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(checks: PullsMergeCheck[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_diffstat (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_activity (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(entries: PullsActivityEntry[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_comments (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(comments: PullsComment[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_commits (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(commits: PullsCommit[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_diff (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(files: DiffFile[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_commit_status (fun(pr: PullRequest, commit: PullsCommit, opts: { force_refresh: boolean|nil }|nil, on_done: fun(status: string|nil, url: string|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---
---@field add_comment (fun(pr: PullRequest, content: string, opts: PullsAddCommentOpts|nil, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reply_comment (fun(pr: PullRequest, parent: PullsComment, content: string, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_comment (fun(pr: PullRequest, comment: PullsComment, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_comment (fun(pr: PullRequest, target: PullsComment, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---
---@field toggle_subscription (fun(pr: PullRequest, on_done: fun(is_subscribed: boolean|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---
---@field views fun(): AtlasPullsViewConfig[]
---@field open_actions fun(pr: PullRequest|nil, source: "main"|"panel"|nil, on_done: fun(result: PullsActionResult|nil))|nil
---@field search fun()|nil
---
---@field fetch_notifications (fun(opts: { force_load: boolean|nil }|nil, on_done: fun(notifications: AtlasNotification[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field mark_notification_read (fun(id: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field mark_notification_done (fun(id: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---
--- Features:
---@field create_pr (fun(opts: PullsCreatePROpts, on_done: fun(result: PullsCreatePRResult|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_default_reviewers (fun(opts: { repo_slug: string, repo_root: string|nil, head: string, base: string }, on_done: fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---
--- Main list rendering
---@field render (fun(groups: PullsGroup[], layout: string, opts: { width: integer }): PullsMainRenderResult)|nil
---
---@field panel PullsProviderPanel|nil
---@field repo_panel PullsProviderRepoPanel|nil
---
---@field health fun()|nil

--------------------------------------------------------------------------------
-- Provider Panel Interface
--------------------------------------------------------------------------------

---@class PullsAddCommentOpts
---@field parent PullsComment|nil          -- reply to this comment
---@field inline { path: string, side: "old"|"new"|nil, line: integer }|nil
---@field is_task boolean|nil              -- create as task

---@class PullsProviderPanel
---@field header_rows (fun(pr: PullRequest): PullsPanelHeaderRow[])|nil
---@field chips (fun(pr: PullRequest): PullsPanelChip[])|nil
---@field tabs (fun(): PullsPanelTab[])|nil
---@field fetches (fun(pr: PullRequest, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field is_loading (fun(pr: PullRequest, active_tab: string|nil): boolean)|nil

---@class PullsProviderPanelKeymaps
---@field register fun(buf: integer)
---@field remove fun(buf: integer)

---@class PullsProviderRepoPanel
---@field header_rows (fun(repo: PullsRepo): PullsPanelHeaderRow[])|nil
---@field chips (fun(repo: PullsRepo): PullsPanelChip[])|nil
---@field tabs (fun(): PullsRepoPanelTab[])|nil
---@field fetches (fun(repo: PullsRepo, refresh: fun()))|nil
---@field is_loading (fun(repo: PullsRepo): boolean)|nil

--------------------------------------------------------------------------------
-- Panel types
--------------------------------------------------------------------------------

---@class PullsPanelHeaderRow
---@field k1 string
---@field v1 string
---@field v1_hl string|table[] hl group name, or list of {start_col, end_col, hl_group} relative to the v1 cell
---@field k2 string
---@field v2 string
---@field v2_hl string|table[] hl group name, or list of {start_col, end_col, hl_group} relative to the v2 cell

---@class PullsPanelChip
---@field label string
---@field hl string|nil

---@class PullsPanelTabModule
---@field render fun(pr: PullRequest, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(pr: PullRequest, repo: PullsRepo|nil, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field activate (fun(buf: integer|nil, refresh: fun()|nil))|nil
---@field deactivate (fun(buf: integer|nil))|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(pr: PullRequest, entry: table): boolean|nil)|nil

---@class PullsPanelTab
---@field key string
---@field label string
---@field icon string|nil
---@field mod PullsPanelTabModule
---@field keymaps PullsProviderPanelKeymaps|nil provider-specific keymaps registered while this tab is active

--------------------------------------------------------------------------------
-- Repo panel types
--------------------------------------------------------------------------------

---@class PullsRepoPanelTabModule
---@field render fun(repo: PullsRepo, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(pr: PullRequest|nil, repo: PullsRepo, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field activate (fun(buf: integer|nil, refresh: fun()|nil))|nil
---@field deactivate (fun(buf: integer|nil))|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(repo: PullsRepo, entry: table): boolean|nil)|nil
---@field delete_current_branch (fun(refresh: fun()))|nil

---@class PullsRepoPanelTab
---@field key string
---@field label string
---@field icon string|nil
---@field mod PullsRepoPanelTabModule
