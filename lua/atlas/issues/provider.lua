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

---@class IssuesViewConfig : AtlasIssuesViewConfig

---@class IssuesProvider
---@field id string
---@field name string
---@field icon string
---@field hl_group string
---@field resolve fun(value: string, parsed: AtlasParsedUrl|nil): AtlasTarget|nil, string|nil
---@field search_view fun(target: AtlasTarget): IssuesViewConfig
---@field issue_key fun(target: AtlasTarget): string|nil
---@field target (fun(info: AtlasGitRemoteInfo, domain: AtlasDomain, entity: AtlasEntity, number: integer, base_url: string): AtlasTarget)|nil
---@field repositories (fun(options: table): string[])|nil
---@field capabilities IssuesProviderCapabilities

---@class IssuesProviderCapabilities
---@field core IssuesCoreCapability
---@field comments IssuesCommentsCapability|nil
---@field notifications AtlasNotificationsCapability|nil
---@field actions IssuesActionsCapability|nil
---@field ui IssuesUICapability|nil

---@class IssuesCoreCapability
---@field fetch_user fun(on_done: fun(user: IssueUser|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_issues fun(view: IssuesViewConfig, opts: IssuesFetchOpts, on_done: fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)): { cancel: fun() }|nil
---@field fetch_issue fun(issue_key: string, opts: IssuesFetchOpts|nil, on_done: fun(issue: IssueDetails|nil, err: string|nil)): { cancel: fun() }|nil
---@field update_description (fun(issue: IssueDetails, content: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field views fun(): IssuesViewConfig[]
---@field refresh fun()|nil

---@class IssuesCommentsCapability
---@field fetch_activity (fun(issue: Issue, opts: IssuesFetchOpts|nil, on_done: fun(entries: IssueActivityEntry[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_conversation (fun(issue: IssueDetails, opts: { force_refresh: boolean|nil }|nil, on_done: fun(items: IssueConversationItem[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_comment (fun(issue: Issue, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reply_comment (fun(issue: Issue, parent: IssueComment, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_comment (fun(issue: Issue, comment: IssueComment, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_comment (fun(issue: Issue, comment: IssueComment, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_reaction (fun(issue: Issue, item: IssueConversationItem, key: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reaction_options IssueReactionOption[]|nil
---@field comment_completion (fun(): AtlasMarkdownCompletionProvider|nil)|nil

---@class IssuesActionsCapability
---@field items AtlasIssueAction[]
---@field is_available fun(action_id: string, context: AtlasIssueActionContext): boolean
---@field run fun(action_id: string, context: AtlasIssueActionContext, on_done: fun(result: IssuesActionResult|nil, err: string|nil)): boolean

---@class IssuesActionResult
---@field issue_key string|nil
---@field removed boolean|nil

---@class IssuesUICapability
---@field setup fun()|nil
---@field render (fun(groups: IssuesGroup[], layout: "plain"|"compact", opts: { width: integer }): IssuesMainRenderResult)|nil
---@field format_row (fun(issue: Issue, is_child: boolean): table|nil)|nil
---@field cell_hl (fun(row: table, col: table, ctx: { text: string, padded: string, width: integer }): table[]|nil)|nil
---@field panel IssuesProviderPanel|nil

--------------------------------------------------------------------------------
-- Panel interface
--------------------------------------------------------------------------------

---@class IssuesProviderPanel
---@field header_rows (fun(issue: Issue, details: IssueDetails|nil, loading: boolean): IssuesPanelHeaderRow[])|nil
---@field chips (fun(issue: Issue, details: IssueDetails|nil, loading: boolean): IssuesPanelChip[])|nil
---@field tabs (fun(): IssuesPanelTab[])|nil
---@field fetch_header (fun(issue: Issue, details: IssueDetails, opts: { force_refresh: boolean|nil }|nil, on_done: fun()): { cancel: fun() }|nil)|nil

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
---@field render fun(issue: IssueDetails, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(issue: IssueDetails, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field reset (fun())|nil
---@field activate (fun(buf: integer|nil, refresh: fun()|nil))|nil
---@field deactivate (fun(buf: integer|nil))|nil
---@field is_loading (fun(): boolean)|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(issue: Issue, entry: table): boolean|nil)|nil

---@class IssuesPanelTab
---@field key string
---@field label string
---@field icon string|nil
---@field icon_hl string|nil
---@field mod IssuesPanelTabModule
