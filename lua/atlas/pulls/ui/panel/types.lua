--------------------------------------------------------------------------------
-- Shared panel types
--------------------------------------------------------------------------------

---@class PullsPanelHeaderRow
---@field k1 string
---@field k1_hl? string
---@field v1 string
---@field v1_hl string|table[] hl group name, or list of {start_col, end_col, hl_group} relative to the v1 cell
---@field k2 string
---@field k2_hl? string
---@field v2 string
---@field v2_hl string|table[] hl group name, or list of {start_col, end_col, hl_group} relative to the v2 cell

---@class PullsPanelChip
---@field label string
---@field hl string|nil

---@class PullsPanelTab
---@field key string
---@field label string
---@field icon string|nil
---@field icon_hl string|nil

--------------------------------------------------------------------------------
-- Pull-request panel
--------------------------------------------------------------------------------

---@class PullsProviderPRPanel
---@field header_rows (fun(pr: PullRequest, loading: boolean): PullsPanelHeaderRow[])|nil
---@field chips (fun(pr: PullRequest, loading: boolean): PullsPanelChip[])|nil
---@field tabs (fun(): PullsPRPanelTab[])|nil
---@field fetch_header (fun(pr: PullRequest, opts: { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil, on_done: fun()): { cancel: fun() }|nil)|nil

---@class PullsPRPanelKeymaps
---@field register fun(buf: integer)
---@field remove fun(buf: integer)

---@class PullsPRPanelTabModule
---@field render fun(pr: PullRequest, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(pr: PullRequest, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field reset (fun())|nil
---@field activate (fun(buf: integer|nil, refresh: fun()|nil))|nil
---@field deactivate (fun(buf: integer|nil))|nil
---@field is_loading (fun(): boolean)|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(pr: PullRequest, entry: table): boolean|nil)|nil

---@class PullsPRPanelTab : PullsPanelTab
---@field mod PullsPRPanelTabModule
---@field keymaps PullsPRPanelKeymaps|nil provider-specific keymaps registered while this tab is active

--------------------------------------------------------------------------------
-- Repository panel
--------------------------------------------------------------------------------

---@class PullsProviderRepoPanel
---@field tabs fun(): PullsRepoPanelTab[]

---@class PullsRepoPanelTabModule
---@field render fun(repo: PullsRepo, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(repo: PullsRepo, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field activate (fun(buf: integer|nil, refresh: fun()|nil))|nil
---@field deactivate (fun(buf: integer|nil))|nil
---@field is_loading (fun(): boolean)|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(repo: PullsRepo, entry: table): boolean|nil)|nil

---@class PullsRepoPanelTab : PullsPanelTab
---@field mod PullsRepoPanelTabModule

return {}
