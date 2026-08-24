local M = {}

local markdown_editor = require("atlas.ui.popups.editor")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local templates_root = vim.fn.stdpath("data") .. "/atlas/issues/templates"

---@class IssueTemplateInfo
---@field name string
---@field path string

---@class AtlasIssueTemplateContext
---@field get_description fun(): string
---@field set_description fun(description: string): boolean
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

---@param title string
---@param templates IssueTemplateInfo[]
---@param on_select fun(template: IssueTemplateInfo|nil)
function M.pick(title, templates, on_select)
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
			local content, read_err = M.read(template.name)
			done({
				title = template.name,
				lines = vim.split(read_err or (content ~= "" and content or "Empty template"), "\n", { plain = true }),
			})
		end,
		on_select = on_select,
	})
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
		{ id = "create", label = "Create template" },
		{ id = "edit", label = "Edit template" },
	}

	picker.select({
		title = "Templates",
		items = options,
		kind = "atlas_issue_template_actions",
		format_item = function(item)
			return item.label
		end,
		on_select = function(choice)
			if choice == nil then
				finish()
				return
			end

			if choice.id == "create" then
				markdown_editor.open({
					key = string.format("template_new_%d", vim.loop.hrtime()),
					title = " New Issue Template ",
					initial_text = "",
					on_save = function(text)
						local markdown = tostring(text or "")
						vim.ui.input({ prompt = "Template name: " }, function(name_input)
							if name_input == nil then
								finish()
								return
							end

							local name = vim.trim(name_input)
							if name == "" then
								finish("Template name is required")
								return
							end

							local ok, write_err, existed, normalized_name =
								M.write(name, markdown, { overwrite = false })
							if ok then
								finish()
								return
							end
							if not existed then
								finish(write_err or "Failed to create template")
								return
							end

							vim.ui.input({
								prompt = string.format(
									'Template "%s" exists. Overwrite? [y/N]: ',
									tostring(normalized_name or name)
								),
							}, function(confirm)
								if vim.trim(confirm or ""):lower() ~= "y" then
									finish()
									return
								end

								local overwrite_ok, overwrite_err = M.write(name, markdown, { overwrite = true })
								if not overwrite_ok then
									finish(overwrite_err or "Failed to overwrite template")
									return
								end
								finish()
							end)
						end)
					end,
					on_cancel = function()
						finish()
					end,
				})
				return
			end

			local templates, list_err = M.list()
			if list_err then
				finish(list_err)
				return
			end
			if templates == nil or #templates == 0 then
				finish()
				return
			end

			M.pick("Edit template", templates, function(selected)
				if selected == nil then
					finish()
					return
				end

				local content, read_err = M.read(selected.name)
				if read_err then
					finish(read_err)
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

									local deleted, delete_err = M.delete(selected.name)
									if not deleted then
										finish(delete_err or "Failed to delete template")
										return
									end

									editor_context.close()
									finish()
								end)
							end,
						},
					},
					on_save = function(text)
						local ok, write_err = M.write(selected.name, text, { overwrite = true })
						if not ok then
							finish(write_err or "Failed to update template")
							return
						end
						finish()
					end,
					on_cancel = function()
						finish()
					end,
				})
			end)
		end,
	})
end

---@param context AtlasIssueTemplateContext
local function apply_template(context)
	local templates, err = M.list()
	if err then
		notify.error(err, { vim_notify = true })
		return
	end
	if templates == nil or #templates == 0 then
		notify.warn("No templates found", { vim_notify = true })
		return
	end

	M.pick("Apply template", templates, function(template)
		if template == nil then
			return
		end

		local content, read_err = M.read(template.name)
		if read_err then
			notify.error(read_err, { vim_notify = true })
			return
		end

		local function replace()
			if not context.set_description(content or "") then
				notify.error("Issue description buffer is not available", { vim_notify = true })
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

---@param context AtlasIssueTemplateContext
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

		local ok, write_err, existed, normalized_name = M.write(name, description, { overwrite = false })
		local display_name = normalized_name or name
		if ok then
			notify.info("Created template " .. display_name, { vim_notify = true })
			return
		end
		if not existed then
			notify.error(write_err or "Failed to create template", { vim_notify = true })
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
					notify.error(overwrite_err or "Failed to overwrite template", { vim_notify = true })
					return
				end
				notify.info("Updated template " .. (final_name or display_name), { vim_notify = true })
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

	picker.select({
		title = "Issue templates",
		items = actions,
		kind = context.menu_kind,
		format_item = function(action)
			return action.label
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
