local M = {}

local comments = require("atlas.pulls.diff.comments")
local icons = require("atlas.ui.shared.icons")
local review = require("atlas.pulls.diff.review")
local session_api = require("atlas.pulls.diff.session")
local comment_icon = icons.general("comment")
local note_icon, note_icon_hl = icons.general("pin")
local file_formatter

---@class AtlasCodeDiffSelection
---@field path string
---@field old_path string|nil
---@field status string|nil
---@field group string|nil

---@class AtlasCodeDiffExplorer
---@field bufnr integer|nil
---@field winid integer|nil
---@field current_selection AtlasCodeDiffSelection|nil
---@field current_file_path string|nil
---@field status_result table<string, AtlasCodeDiffSelection[]>|nil
---@field tree table|nil
---@field on_file_select (fun(selection: AtlasCodeDiffSelection, opts: { no_jump: boolean }|nil))|nil

---@param value string|nil
---@return string
local function clean_path(value)
	local path = tostring(value or "")
	return (path:gsub("\\", "/"):gsub("/+$", ""))
end

---@param root string
---@param path string|nil
---@return string
function M.relative_path(root, path)
	path = clean_path(path)
	root = clean_path(root)
	local prefix = root ~= "" and root .. "/" or ""
	if prefix ~= "" and path:sub(1, #prefix) == prefix then
		return path:sub(#prefix + 1)
	end
	return (path:gsub("^%./", ""))
end

---@param lifecycle AtlasCodeDiffLifecycle
---@param tabpage integer
---@return AtlasCodeDiffExplorer|nil
function M.get(lifecycle, tabpage)
	-- CodeDiff v2.67.2 changed explorer and history access under the panel API.
	if lifecycle.get_panel_view then
		if lifecycle.get_panel_name and lifecycle.get_panel_name(tabpage) ~= "explorer" then
			return nil
		end
		return lifecycle.get_panel_view(tabpage)
	end
	if lifecycle.get_explorer then
		return lifecycle.get_explorer(tabpage)
	end
	return nil
end

---@param explorer AtlasCodeDiffExplorer|nil
---@return AtlasCodeDiffSelection|nil
local function current_file(explorer)
	if not explorer then
		return nil
	end
	local file = explorer.current_selection
	if vim.api.nvim_get_current_buf() == explorer.bufnr then
		local node = explorer.tree and explorer.tree:get_node()
		file = node and node.data
		if not file or file.type == "group" or file.type == "directory" then
			return nil
		end
	end
	return file and file.path and file or nil
end

---@param session AtlasDiffSession
---@param explorer AtlasCodeDiffExplorer|nil
function M.render(session, explorer)
	if not session.review or not explorer or not explorer.tree then
		return
	end
	if explorer.bufnr and vim.api.nvim_buf_is_valid(explorer.bufnr) then
		local files = {}
		for _, group in pairs(explorer.status_result or {}) do
			vim.list_extend(files, group)
		end
		session.viewer_state.annotated_paths = comments.annotated_paths(session, files)
		explorer.tree:render()
	end
end

---@param session AtlasDiffSession
---@param pending boolean
function M.add_file_comment(session, pending)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	local explorer = M.get(state.lifecycle, state.tabpage)
	local file = current_file(explorer)
	if file then
		comments.add_to_file(session, {
			path = M.relative_path(session.source.root, file.path),
			old_path = file.old_path and M.relative_path(session.source.root, file.old_path) or nil,
		}, pending)
	end
end

function M.toggle_file_reviewed()
	local session = session_api.get()
	if not session or session.viewer_id ~= "codediff" then
		return
	end
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	if state.closed or session.closed or not session.review then
		return
	end
	local explorer = M.get(state.lifecycle, state.tabpage)
	local file = current_file(explorer)
	if not file then
		return
	end
	local path = M.relative_path(session.source.root, file.path)
	review.set_file_reviewed(session, path, not session.reviewed_files[path])
	session:render()
	if not session.current then
		M.render(session, explorer)
	end
end

---@param session AtlasDiffSession
---@param explorer AtlasCodeDiffExplorer|nil
function M.attach(session, explorer)
	if not session.review or not explorer or not explorer.tree then
		return
	end
	local available, defaults = pcall(require, "codediff.ui.explorer.formatters")
	if not available then
		return
	end
	local formatters = require("codediff.config").options.explorer.formatters
	if not file_formatter or formatters.file ~= file_formatter then
		local format_file = formatters.file or defaults.file
		file_formatter = function(ctx)
			-- CodeDiff's formatter provides file details without a tab or repository.
			local current = session_api.get()
			if not current or current.viewer_id ~= "codediff" or current.closed then
				return format_file(ctx)
			end
			if current.reviewed_files[ctx.path] then
				ctx.icon, ctx.icon_hl = icons.general("success")
			end
			local paths = current.viewer_state.annotated_paths
			local annotation = paths[ctx.path]
			local markers = {}
			if annotation and annotation.comments then
				markers[#markers + 1] = { text = " " .. comment_icon, hl = "AtlasLogInfo" }
			end
			if annotation and annotation.notes then
				markers[#markers + 1] = { text = " " .. note_icon, hl = note_icon_hl }
			end
			local layout = format_file(ctx)
			if #markers > 0 then
				layout = vim.deepcopy(layout)
				layout.left = layout.left or {}
				table.insert(layout.left, { segments = markers })
			end
			return layout
		end
		formatters.file = file_formatter
	end
	M.render(session, explorer)
end

return M
