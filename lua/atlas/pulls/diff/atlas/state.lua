local M = {}

---@alias AtlasNativeDiffLayout "side-by-side"|"inline"

---@class AtlasNativeDiffWindow
---@field buf integer
---@field win integer|nil

---@class AtlasNativeDiffSessionOptions
---@field layout AtlasNativeDiffLayout
---@field compact boolean
---@field explorer AtlasDiffExplorerOptions

---@alias AtlasNativeDiffPanelItem
---| { kind: "file", index: integer }
---| { kind: "folder", path: string }

---@class AtlasNativeDiffSession
---@field tabpage integer
---@field range AtlasNativeDiffRange
---@field files DiffFile[]
---@field selected_index integer
---@field pending_index integer|nil
---@field layout AtlasNativeDiffLayout
---@field compact boolean
---@field number boolean
---@field relativenumber boolean
---@field explorer AtlasDiffExplorerOptions
---@field reviewed_files table<string, boolean>
---@field collapsed_folders table<string, boolean>
---@field panel_items table<integer, AtlasNativeDiffPanelItem>
---@field panel AtlasNativeDiffWindow
---@field left AtlasNativeDiffWindow
---@field right AtlasNativeDiffWindow
---@field footer AtlasNativeDiffFooter
---@field job { cancel: fun() }|nil
---@field document AtlasNativeDiffDocument
---@field reload fun()
---@field refresh_ui fun()
---@field closing boolean

---@class AtlasNativeDiffOpenOptions
---@field diff AtlasPreparedDiff
---@field explorer AtlasDiffExplorerOptions
---@field reload fun()

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
