local M = {}

local namespace = vim.api.nvim_create_namespace("atlas.diff.images")
local directory = vim.fn.tempname()

---@param file { path: string, binary_content?: string }
---@return boolean
local function supported(file)
	return file.binary_content ~= nil and require("snacks.image").supports_file(file.path)
end

---@param document AtlasDiffDocument
---@return boolean
local function supports(document)
	if not document.binary then
		return false
	end
	local ok, snacks = pcall(require, "snacks")
	return ok and snacks.config.image.enabled == true and (supported(document.old) or supported(document.new))
end

---@param root string
---@param revision string
---@param file { path: string, binary_content?: string }
---@return string
local function image_file(root, revision, file)
	local key = vim.fn.sha256(root .. ":" .. revision .. ":" .. file.path)
	local path = directory .. "/" .. key .. "." .. vim.fn.fnamemodify(file.path, ":e")
	if vim.fn.filereadable(path) == 0 then
		vim.fn.mkdir(directory, "p")
		local output = assert(io.open(path, "wb"))
		assert(output:write(file.binary_content))
		assert(output:close())
	end
	return path
end

---@param document AtlasDiffDocument
---@param win integer
function M.configure_window(document, win)
	local options = vim.wo[win][0]
	options.signcolumn = vim.go.signcolumn
	options.statuscolumn = vim.go.statuscolumn
	if supports(document) then
		options.number = false
		options.relativenumber = false
		options.signcolumn = "no"
		options.statuscolumn = ""
	end
end

---@param state AtlasNativeDiffState
function M.clear(state)
	if supports(state.document) then
		local image = require("snacks.image")
		for _, pane in ipairs({ state.left, state.right }) do
			image.placement.clean(pane.buf)
			vim.api.nvim_buf_clear_namespace(pane.buf, namespace, 0, -1)
		end
	end
end

---@param buf integer
local function clear_buffer(buf)
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	vim.bo[buf].readonly = true
end

---@param root string
---@param pane AtlasDiffWindow
---@param revision string
---@param file { path: string, binary_content?: string }
local function attach_image(root, pane, revision, file)
	if not pane.win or not supported(file) then
		return
	end
	local path = image_file(root, revision, file)
	clear_buffer(pane.buf)
	vim.api.nvim_buf_set_extmark(pane.buf, namespace, 0, 0, {
		virt_text = { { "Loading image…", "AtlasTextMuted" } },
	})
	require("snacks.image").buf.attach(pane.buf, {
		src = path,
		inline = true,
		on_update_pre = function(placement)
			if #placement:state().wins == 0 then
				placement:del()
			end
		end,
		on_update = function()
			vim.api.nvim_buf_clear_namespace(pane.buf, namespace, 0, -1)
		end,
	})
end

---@param session AtlasDiffSession
function M.attach(session)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	if not supports(state.document) then
		return
	end
	local document = state.document
	local image = require("snacks.image")
	image.terminal.detect(function()
		if state.closing or state.document ~= document then
			return
		end
		if not image.supports_terminal() then
			return
		end
		attach_image(session.source.root, state.left, session.source.base_revision, document.old)
		attach_image(session.source.root, state.right, session.source.head_revision, document.new)
	end)
end

return M
