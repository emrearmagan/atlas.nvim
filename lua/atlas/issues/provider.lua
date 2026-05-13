--------------------------------------------------------------------------------
-- Main render result
--------------------------------------------------------------------------------

---@class IssuesMainRenderResult
---@field lines string[]
---@field spans table[]
---@field line_map table<integer, table>

--------------------------------------------------------------------------------
-- Provider Interface
--------------------------------------------------------------------------------

---@class IssuesFetchOpts
---@field force_load boolean|nil
---@field max_results number|nil
---@field next_page_token string|nil
---@field layout "plain"|"compact"|nil
---@field with_relationships boolean|nil

---@class IssuesViewConfig
---@field name string
---@field key string
---@field layout "plain"|"compact"|nil

---@class IssuesProvider
---@field id string
---@field name string
---@field icon string
---@field hl_group string
---
---@field setup fun()|nil
---@field on_refresh fun()|nil
---
---@field fetch_user fun(on_done: fun(user: IssueUser|nil, err: string|nil))
---@field fetch_issues fun(view: IssuesViewConfig, opts: IssuesFetchOpts, on_done: fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)): { cancel: fun() }|nil
---@field fetch_issue fun(issue_key: string, opts: IssuesFetchOpts|nil, on_done: fun(issue: Issue|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_description fun(issue_key: string, opts: IssuesFetchOpts|nil, on_done: fun(raw: any, err: string|nil)): { cancel: fun() }|nil
---@field fetch_comments fun(issue_key: string, opts: IssuesFetchOpts|nil, on_done: fun(comments: IssueComment[]|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_history (fun(issue_key: string, opts: IssuesFetchOpts|nil, on_done: fun(entries: IssueHistoryEntry[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_comment (fun(issue_key: string, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reply_comment (fun(issue_key: string, parent_id: string, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_comment (fun(issue_key: string, comment_id: string, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_comment (fun(issue_key: string, comment_id: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---
---@field toggle_subscription (fun(issue: Issue, on_done: fun(is_subscribed: boolean|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---
---@field views fun(): IssuesViewConfig[]
---@field run_action fun(action_id: string, ctx: table, on_done: fun(result: table|nil, err: string|nil))|nil
---@field open_actions fun(issue: Issue|nil, source: "main"|"panel"|nil, on_done: fun(result: table|nil, err: string|nil))|nil
---@field search fun(on_done: fun(result: table|nil, err: string|nil)|nil)|nil
---@field create_issue (fun(opts: table, on_done: fun(result: table|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---
---@field fetch_notifications (fun(opts: { force_load: boolean|nil }|nil, on_done: fun(notifications: AtlasNotification[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field mark_notification_read (fun(id: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field mark_notification_done (fun(id: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---
--- Main UI Style
---@field render (fun(groups: IssuesGroup[], layout: "plain"|"compact", opts: { width: integer }): IssuesMainRenderResult)|nil
---@field format_row fun(issue: Issue, is_child: boolean): table|nil
---@field cell_hl fun(row: table, col: table, ctx: { text: string, padded: string, width: integer }): table[]|nil|nil
---
---@field panel IssuesProviderPanel|nil
---
---@field health fun()|nil

--------------------------------------------------------------------------------
-- Panel interface
--------------------------------------------------------------------------------

---@class IssuesProviderPanel
---@field header_rows (fun(issue: Issue): IssuesPanelHeaderRow[])|nil
---@field chips (fun(issue: Issue): IssuesPanelChip[])|nil
---@field tabs (fun(): IssuesPanelTab[])|nil
---@field fetches (fun(issue: Issue, refresh: fun(), opts: { force_load?: boolean }|nil))|nil
---@field is_loading (fun(issue: Issue): boolean)|nil
---@field convert_description (fun(raw: any): string|nil)|nil
---@field format_history_item (fun(item: IssueHistoryItem): { label: string, content: string|nil })|nil
---@field history_item_hl (fun(item: IssueHistoryItem, row: string, row_index: integer): table[]|nil)|nil
---@field comment_completion (fun(): AtlasMarkdownCompletionProvider|nil)|nil
---@field resolve_comment_body (fun(body: string): string)|nil

--------------------------------------------------------------------------------
-- Panel types
--------------------------------------------------------------------------------

---@class IssuesPanelHeaderRow
---@field k1 string
---@field v1 string
---@field v1_hl string|table[]|nil hl group name, or list of {start_col, end_col, hl_group} relative to the v1 cell
---@field k2 string
---@field v2 string
---@field v2_hl string|table[]|nil hl group name, or list of {start_col, end_col, hl_group} relative to the v2 cell

---@class IssuesPanelChip
---@field label string
---@field hl string|nil

---@class IssuesPanelTabModule
---@field render fun(issue: Issue, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(issue: Issue, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field activate (fun(buf: integer|nil, refresh: fun()|nil))|nil
---@field deactivate (fun(buf: integer|nil))|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(issue: Issue, entry: table): boolean|nil)|nil

---@class IssuesPanelTab
---@field key string
---@field label string
---@field icon string|nil
---@field mod IssuesPanelTabModule
