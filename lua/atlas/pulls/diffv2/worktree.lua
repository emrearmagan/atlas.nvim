-- Some helper functions for when lsp is enabled
local M = {}

---@param root string|nil
---@param path string
---@return string|nil
function M.relative_path(root, path)
	if not root then
		return
	end

	-- Linked dependencies may live outside the checkout.
	root = vim.uv.fs_realpath(root)
	local resolved_path = vim.uv.fs_realpath(path)
	if root and resolved_path and resolved_path:sub(1, #root + 1) == root .. "/" then
		return resolved_path:sub(#root + 2)
	end
end

---@param buf integer
function M.protect(buf)
	-- Keep the filename and buftype so the user's LSP can attach.
	vim.b[buf].atlas_diff = true
	vim.bo[buf].buflisted = false
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].readonly = true
	vim.bo[buf].modifiable = false
end

---@param root string
---@param path string
---@return integer|nil
function M.load(root, path)
	local full_path = vim.fs.joinpath(root, path)
	if vim.fn.filereadable(full_path) ~= 1 or not M.relative_path(root, full_path) then
		return
	end

	local buf = vim.fn.bufadd(full_path)
	if vim.bo[buf].modified then
		return
	end
	if not pcall(vim.fn.bufload, buf) then
		return
	end

	M.protect(buf)
	return buf
end

-- Clear file buffers before removing their checkout.
---@param root string
function M.cleanup(root)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if not vim.bo[buf].modified and M.relative_path(root, vim.api.nvim_buf_get_name(buf)) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
end

return M
