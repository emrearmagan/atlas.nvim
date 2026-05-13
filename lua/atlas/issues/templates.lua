local M = {}

local templates_root = vim.fn.stdpath("data") .. "/atlas/issues/templates"

---@class IssueTemplateInfo
---@field name string
---@field path string

---@param name string|nil
---@return string|nil
---@return string|nil
local function normalize_name(name)
	local normalized = vim.trim(tostring(name or ""))
	if normalized == "" then
		return nil, "Template name is required"
	end

	normalized = normalized:gsub("%.md$", "")
	normalized = normalized:gsub("[/\\]", "-")
	normalized = vim.trim(normalized)

	if normalized == "" then
		return nil, "Template name is required"
	end

	return normalized, nil
end

---@return boolean
---@return string|nil
local function ensure_templates_dir()
	if vim.fn.isdirectory(templates_root) == 0 then
		vim.fn.mkdir(templates_root, "p")
	end

	if vim.fn.isdirectory(templates_root) == 0 then
		return false, "Failed to create templates directory"
	end

	return true, nil
end

---@param name string
---@return string|nil path
---@return string|nil normalized_name
---@return string|nil err
local function path_for_name(name)
	local normalized_name, normalize_err = normalize_name(name)
	if normalized_name == nil then
		return nil, nil, normalize_err
	end

	return string.format("%s/%s.md", templates_root, normalized_name), normalized_name, nil
end

---@return IssueTemplateInfo[]|nil
---@return string|nil
function M.list()
	local ok, ensure_err = ensure_templates_dir()
	if not ok then
		return nil, ensure_err
	end

	local paths = vim.fn.globpath(templates_root, "*.md", false, true) or {}
	table.sort(paths, function(a, b)
		return a:lower() < b:lower()
	end)

	---@type IssueTemplateInfo[]
	local templates = {}
	for _, path in ipairs(paths) do
		if vim.fn.filereadable(path) == 1 then
			table.insert(templates, {
				name = vim.fn.fnamemodify(path, ":t:r"),
				path = path,
			})
		end
	end

	return templates, nil
end

---@param name string
---@return string|nil
---@return string|nil
function M.read(name)
	local path, normalized_name, path_err = path_for_name(name)
	if path == nil then
		return nil, path_err
	end

	if vim.fn.filereadable(path) == 0 then
		return nil, string.format('Template "%s" not found', tostring(normalized_name))
	end

	local lines = vim.fn.readfile(path)
	return table.concat(lines, "\n"), nil
end

---@param name string
---@param content string|nil
---@param opts? { overwrite?: boolean }
---@return boolean ok
---@return string|nil err
---@return boolean existed
---@return string|nil normalized_name
function M.write(name, content, opts)
	opts = opts or {}

	local path, normalized_name, path_err = path_for_name(name)
	if path == nil then
		return false, path_err, false, nil
	end

	local ok, ensure_err = ensure_templates_dir()
	if not ok then
		return false, ensure_err, false, normalized_name
	end

	local existed = vim.fn.filereadable(path) == 1
	if existed and opts.overwrite ~= true then
		return false, string.format('Template "%s" already exists', tostring(normalized_name)), true, normalized_name
	end

	local lines = vim.split(tostring(content or ""), "\n", { plain = true })
	local write_ok, write_err = pcall(vim.fn.writefile, lines, path)
	if not write_ok then
		return false, tostring(write_err), existed, normalized_name
	end

	return true, nil, existed, normalized_name
end

---@param name string
---@return boolean ok
---@return string|nil err
---@return string|nil normalized_name
function M.delete(name)
	local path, normalized_name, path_err = path_for_name(name)
	if path == nil then
		return false, path_err, nil
	end

	if vim.fn.filereadable(path) == 0 then
		return false, string.format('Template "%s" not found', tostring(normalized_name)), normalized_name
	end

	local delete_ok, delete_err = pcall(vim.fn.delete, path)
	if not delete_ok then
		return false, tostring(delete_err), normalized_name
	end

	if vim.fn.filereadable(path) == 1 then
		return false, string.format('Failed to delete template "%s"', tostring(normalized_name)), normalized_name
	end

	return true, nil, normalized_name
end

return M
