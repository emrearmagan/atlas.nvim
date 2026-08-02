local M = {}

local notify = require("atlas.core.notify")
local templates_root = vim.fn.stdpath("data") .. "/atlas/issues/templates"

---@class IssueTemplateInfo
---@field name string
---@field path string

---@class AtlasIssueTemplateContext
---@field get_description fun(): string
---@field set_description fun(description: string): boolean
---@field picker_kind string
---@field menu_kind string

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

---@param context AtlasIssueTemplateContext
local function apply_template(context)
	local templates, err = M.list()
	if err then
		notify.error(err)
		return
	end
	if templates == nil or #templates == 0 then
		notify.warn("No templates found")
		return
	end

	vim.ui.select(templates, {
		prompt = "Apply template",
		kind = context.picker_kind,
		format_item = function(template)
			return template.name
		end,
	}, function(template)
		if template == nil then
			return
		end

		local content, read_err = M.read(template.name)
		if read_err then
			notify.error(read_err)
			return
		end

		local function replace()
			if not context.set_description(content or "") then
				notify.error("Issue description buffer is not available")
				return
			end
			notify.info("Applied template: " .. template.name)
		end

		if vim.trim(context.get_description()) == "" then
			replace()
			return
		end

		vim.ui.input({ prompt = "Description is not empty. Replace with template? [y/N]: " }, function(input)
			if vim.trim(input or ""):lower() == "y" then
				replace()
			end
		end)
	end)
end

---@param context AtlasIssueTemplateContext
local function save_template(context)
	local description = vim.trim(context.get_description())
	if description == "" then
		notify.warn("Description is empty")
		return
	end

	vim.ui.input({ prompt = "Template name: " }, function(input)
		if input == nil then
			return
		end

		local name = vim.trim(input)
		if name == "" then
			notify.warn("Template name is required")
			return
		end

		local ok, write_err, existed, normalized_name = M.write(name, description, { overwrite = false })
		local display_name = normalized_name or name
		if ok then
			notify.info("Created template " .. display_name)
			return
		end
		if not existed then
			notify.error(write_err or "Failed to create template")
			return
		end

		vim.ui.input(
			{ prompt = string.format('Template "%s" exists. Overwrite? [y/N]: ', display_name) },
			function(confirm)
				if vim.trim(confirm or ""):lower() ~= "y" then
					return
				end

				local overwrite_ok, overwrite_err, _, final_name = M.write(name, description, { overwrite = true })
				if not overwrite_ok then
					notify.error(overwrite_err or "Failed to overwrite template")
					return
				end
				notify.info("Updated template " .. (final_name or display_name))
			end
		)
	end)
end

---@param context AtlasIssueTemplateContext
function M.open(context)
	local actions = {
		{ id = "apply", label = "Apply template" },
		{ id = "save", label = "Save current description as template" },
	}

	vim.ui.select(actions, {
		prompt = "Issue templates",
		kind = context.menu_kind,
		format_item = function(action)
			return action.label
		end,
	}, function(action)
		if action == nil then
			return
		end
		if action.id == "apply" then
			apply_template(context)
		else
			save_template(context)
		end
	end)
end

return M
