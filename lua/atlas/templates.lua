local M = {}

local icons = require("atlas.ui.shared.icons")
local markdown_editor = require("atlas.ui.popups.editor")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local templates_root = vim.fn.stdpath("data") .. "/atlas/issues/templates"

---@class AtlasTemplateInfo
---@field name string
---@field path string

---@class AtlasTemplateContext
---@field get_description fun(): string
---@field set_description fun(description: string): boolean

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

---@return AtlasTemplateInfo[]|nil
---@return string|nil
local function list()
	local ok, ensure_err = ensure_templates_dir()
	if not ok then
		return nil, ensure_err
	end

	local paths = vim.fn.globpath(templates_root, "*.md", false, true) or {}
	table.sort(paths, function(a, b)
		return a:lower() < b:lower()
	end)

	---@type AtlasTemplateInfo[]
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
local function read(name)
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

---@param title string
---@param templates AtlasTemplateInfo[]
---@param on_select fun(template: AtlasTemplateInfo|nil)
local function pick(title, templates, on_select)
	picker.select_with_preview({
		title = title,
		items = templates,
		key = function(template)
			return template.path
		end,
		format_item = function(template)
			return template.name
		end,
		preview_item = function(template, done)
			local content, read_err = read(template.name)
			done({
				title = template.name,
				lines = vim.split(read_err or (content ~= "" and content or "Empty template"), "\n", { plain = true }),
			})
		end,
		on_select = on_select,
	})
end

---@param name string
---@param content string|nil
---@param opts? { overwrite?: boolean }
---@return boolean ok
---@return string|nil err
---@return boolean existed
---@return string|nil normalized_name
local function write(name, content, opts)
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
---@param content string
---@param on_done fun(name: string|nil, err: string|nil, overwritten: boolean|nil)
local function write_with_confirmation(name, content, on_done)
	local ok, err, existed, normalized_name = write(name, content, { overwrite = false })
	local display_name = normalized_name or name
	if ok then
		on_done(display_name, nil, false)
		return
	end
	if not existed then
		on_done(nil, err or "Failed to create template")
		return
	end

	vim.ui.input({ prompt = string.format('Template "%s" exists. Overwrite? [y/N]: ', display_name) }, function(confirm)
		if vim.trim(confirm or ""):lower() ~= "y" then
			on_done()
			return
		end

		local overwrite_ok, overwrite_err, _, final_name = write(name, content, { overwrite = true })
		if not overwrite_ok then
			on_done(nil, overwrite_err or "Failed to overwrite template")
			return
		end
		on_done(final_name or display_name, nil, true)
	end)
end

---@param name string
---@return boolean ok
---@return string|nil err
---@return string|nil normalized_name
local function delete(name)
	local path, normalized_name, path_err = path_for_name(name)
	if path == nil then
		return false, path_err, nil
	end

	if vim.fn.filereadable(path) == 0 then
		return false, string.format('Template "%s" not found', tostring(normalized_name)), normalized_name
	end

	if vim.fn.delete(path) ~= 0 then
		return false, string.format('Failed to delete template "%s"', tostring(normalized_name)), normalized_name
	end

	return true, nil, normalized_name
end

---@param on_done fun(err: string|nil)
local function create_template(on_done)
	markdown_editor.open({
		key = string.format("template_new_%d", vim.loop.hrtime()),
		title = " New Template ",
		initial_text = "",
		on_save = function(text)
			local markdown = tostring(text or "")
			vim.ui.input({ prompt = "Template name: " }, function(name_input)
				if name_input == nil then
					on_done()
					return
				end

				local name = vim.trim(name_input)
				if name == "" then
					on_done("Template name is required")
					return
				end

				write_with_confirmation(name, markdown, function(_, err)
					on_done(err)
				end)
			end)
		end,
		on_cancel = function()
			on_done()
		end,
	})
end

---@param selected AtlasTemplateInfo
---@param on_done fun(err: string|nil)
local function edit_template(selected, on_done)
	local content, read_err = read(selected.name)
	if read_err then
		on_done(read_err)
		return
	end

	local key = ("template_" .. selected.name):gsub("[^%w%-_]+", "_")
	markdown_editor.open({
		key = key,
		title = string.format(" Template: %s ", selected.name),
		initial_text = content,
		actions = {
			{
				key = "<C-d>",
				description = "delete",
				callback = function(editor_context)
					vim.ui.input({
						prompt = string.format('Delete template "%s"? [y/N]: ', selected.name),
					}, function(confirm)
						if vim.trim(confirm or ""):lower() ~= "y" then
							return
						end

						local deleted, delete_err = delete(selected.name)
						if not deleted then
							on_done(delete_err or "Failed to delete template")
							return
						end

						editor_context.close()
						on_done()
					end)
				end,
			},
		},
		on_save = function(text)
			local ok, write_err = write(selected.name, text, { overwrite = true })
			if not ok then
				on_done(write_err or "Failed to update template")
				return
			end
			on_done()
		end,
		on_cancel = function()
			on_done()
		end,
	})
end

---@param on_done fun(err: string|nil)
function M.manage(on_done)
	local finished = false
	local function finish(err)
		if finished then
			return
		end
		finished = true
		if err then
			notify.error(err)
		end
		on_done(err)
	end

	local options = {
		{ id = "create", label = "Create template", icon = icons.get("create", "actions") },
		{ id = "edit", label = "Edit template", icon = icons.get("edit", "actions") },
	}

	picker.select({
		title = "Templates",
		items = options,
		size = { width = 0.35, height = 0.15 },
		format_item = function(action)
			return (action.icon or icons.get("custom", "actions")) .. "  " .. action.label
		end,
		on_select = function(choice)
			if choice == nil then
				finish()
				return
			end

			if choice.id == "create" then
				create_template(finish)
				return
			end

			local templates, list_err = list()
			if list_err then
				finish(list_err)
				return
			end
			if templates == nil or #templates == 0 then
				finish()
				return
			end

			pick("Edit template", templates, function(selected)
				if selected == nil then
					finish()
					return
				end

				edit_template(selected, finish)
			end)
		end,
	})
end

---@param context AtlasTemplateContext
local function apply_template(context)
	local templates, err = list()
	if err then
		notify.error(err, { vim_notify = true })
		return
	end
	if templates == nil or #templates == 0 then
		notify.warn("No templates found", { vim_notify = true })
		return
	end

	pick("Apply template", templates, function(template)
		if template == nil then
			return
		end

		local content, read_err = read(template.name)
		if read_err then
			notify.error(read_err, { vim_notify = true })
			return
		end

		local function replace()
			if not context.set_description(content or "") then
				notify.error("Description buffer is not available", { vim_notify = true })
				return
			end
			notify.info("Applied template: " .. template.name, { vim_notify = true })
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

---@param context AtlasTemplateContext
local function save_template(context)
	local description = vim.trim(context.get_description())
	if description == "" then
		notify.warn("Description is empty", { vim_notify = true })
		return
	end

	vim.ui.input({ prompt = "Template name: " }, function(input)
		if input == nil then
			return
		end

		local name = vim.trim(input)
		if name == "" then
			notify.warn("Template name is required", { vim_notify = true })
			return
		end

		write_with_confirmation(name, description, function(saved_name, err, overwritten)
			if err then
				notify.error(err, { vim_notify = true })
			elseif saved_name then
				local action = overwritten and "Updated" or "Created"
				notify.info(action .. " template " .. saved_name, { vim_notify = true })
			end
		end)
	end)
end

---@param context AtlasTemplateContext
function M.open(context)
	local actions = {
		{ id = "apply", label = "Apply template", icon = icons.get("success", "actions") },
		{ id = "save", label = "Save current description as template", icon = icons.get("save", "actions") },
	}

	picker.select({
		title = "Templates",
		items = actions,
		size = { width = 0.35, height = 0.15 },
		format_item = function(action)
			return (action.icon or icons.get("custom", "actions")) .. "  " .. action.label
		end,
		on_select = function(action)
			if action == nil then
				return
			end
			if action.id == "apply" then
				apply_template(context)
			else
				save_template(context)
			end
		end,
	})
end

return M
