local M = {}

---@class AtlasNativeDiffSessionOptions
---@field layout AtlasReviewLayout
---@field compact boolean
---@field compact_context_lines integer
---@field show_review_panel boolean
---@field explorer AtlasDiffExplorerOptions

---@alias AtlasNativeDiffPanelItem
---| { kind: "file", index: integer }
---| { kind: "folder", path: string }

---@class AtlasNativeDiffSession: AtlasReviewSession
---@field lifecycle AtlasNativeDiffLifecycle
---@field range AtlasNativeDiffRange
---@field files DiffFile[]
---@field selected_index integer
---@field pending_index integer|nil
---@field compact boolean
---@field compact_context_lines integer
---@field number boolean
---@field relativenumber boolean
---@field explorer AtlasDiffExplorerOptions
---@field reviewed_files table<string, boolean>
---@field collapsed_folders table<string, boolean>
---@field panel_items table<integer, AtlasNativeDiffPanelItem>
---@field panel AtlasReviewWindow
---@field commits PullsCommit[]
---@field commit_items table<integer, PullsCommit>
---@field commits_panel AtlasReviewWindow
---@field commits_visible boolean
---@field statusline AtlasNativeDiffStatusline
---@field job { cancel: fun() }|nil
---@field document AtlasNativeDiffDocument
---@field review_context AtlasPreparedReviewContext|nil
---@field review_attached boolean
---@field review_panel AtlasReviewPanel|nil
---@field reload fun(target: AtlasLoadingTarget|nil)

---@class AtlasNativeDiffLifecycle
---@field session_id string
---@field opened boolean
---@field closed boolean

---@class AtlasNativeDiffOpenOptions
---@field diff AtlasPreparedDiff
---@field explorer AtlasDiffExplorerOptions
---@field review AtlasPreparedReviewContext|nil
---@field commits PullsCommit[]
---@field reload fun(target: AtlasLoadingTarget|nil)
---@field target AtlasLoadingTarget|nil

---@type table<integer, AtlasNativeDiffSession>
local sessions = {}

---@param session AtlasNativeDiffSession
function M.add(session)
	sessions[session.tabpage] = session
end

---@param tabpage integer
---@return AtlasNativeDiffSession|nil
function M.get(tabpage)
	return sessions[tabpage]
end

---@param tabpage integer
function M.remove(tabpage)
	sessions[tabpage] = nil
end

---@return table<integer, AtlasNativeDiffSession>
function M.all()
	return sessions
end

return M
