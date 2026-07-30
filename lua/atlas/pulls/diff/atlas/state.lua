local M = {}

---@class AtlasNativeDiffOpenOptions
---@field diff AtlasPreparedDiff

---@class AtlasNativeDiffSession
---@field tabpage integer
---@field range AtlasNativeDiffRange
---@field files DiffFile[]
---@field selected_index integer|nil
---@field pending_index integer|nil
---@field panel_items table<integer, integer>
---@field panel { buf: integer, win: integer }
---@field content { buf: integer, win: integer }
---@field number boolean
---@field relativenumber boolean
---@field document AtlasNativeDiffDocument
---@field job { cancel: fun() }|nil
---@field closing boolean

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
