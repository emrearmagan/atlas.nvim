local M = {}

local icons = require("atlas.ui.shared.icons")
local keymaps = require("atlas.core.keymaps")
local markdown_editor = require("atlas.ui.popups.editor")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local picker_format = require("atlas.ui.picker.format")
local storage = require("atlas.core.storage")
local templates_root = vim.fs.joinpath(storage.root(), "issues", "templates")

---@class AtlasTemplateInfo
---@field name string
---@field path string

---@class AtlasTemplateContext
---@field get_description fun(): string
---@field set_description fun(description: string): boolean

---@return AtlasTemplateInfo[]
local function list()
	local paths = vim.fn.globpath(templates_root, "*.md", false, true)
	table.sort(paths, function(a, b)
		return a:lower() < b:lower()
	end)
	return vim.tbl_map(function(path)
		return { name = vim.fn.fnamemodify(path, ":t:r"), path = path }
	end, paths)
end

---@param template AtlasTemplateInfo
---@return string|nil content
---@return string|nil err
local function read(template)
	if vim.fn.filereadable(template.path) == 0 then
		return nil, string.format('Template "%s" not found', template.name)
	end
	return table.concat(vim.fn.readfile(template.path), "\n"), nil
end

---@param path string
---@param content string
---@return string|nil err
local function write(path, content)
	vim.fn.mkdir(templates_root, "p")
	local ok, err = pcall(vim.fn.writefile, vim.split(content, "\n", { plain = true }), path)
	return not ok and tostring(err) or nil
end

---@param content string
---@param on_done fun(name: string|nil, err: string|nil, overwritten: boolean|nil)
local function save_as(content, on_done)
	vim.ui.input({ prompt = "Template name: " }, function(input)
		if input == nil then
			on_done()
			return
		end
		local name = vim.trim((vim.trim(input):gsub("%.md$", ""):gsub("[/\\]", "-")))
		if name == "" then
			on_done(nil, "Template name is required")
			return
		end

		local path = string.format("%s/%s.md", templates_root, name)
		local function save(overwritten)
			local err = write(path, content)
			if err then
				on_done(nil, err)
				return
			end
			on_done(name, nil, overwritten)
		end
		if vim.fn.filereadable(path) == 0 then
			save(false)
			return
		end

		vim.ui.input({ prompt = string.format('Template "%s" exists. Overwrite? [y/N]: ', name) }, function(confirm)
			if vim.trim(confirm or ""):lower() == "y" then
				save(true)
			else
				on_done()
			end
		end)
	end)
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
		preview_item = function(template, done, width)
			local content, read_err = read(template)
			done(picker_format.markdown({
				title = template.name,
				lines = vim.split(read_err or (content ~= "" and content or "Empty template"), "\n", { plain = true }),
			}, width))
		end,
		on_select = on_select,
	})
end

---@param on_done fun(err: string|nil)
local function create_template(on_done)
	markdown_editor.open({
		key = string.format("template_new_%d", vim.uv.hrtime()),
		title = " New Template ",
		initial_text = "",
		on_save = function(text)
			save_as(text, function(_, err)
				on_done(err)
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
	local content, read_err = read(selected)
	if read_err then
		on_done(read_err)
		return
	end

	local key = ("template_" .. selected.name):gsub("[^%w%-_]+", "_")
	local actions = {}
	local delete_keymap = keymaps.resolve("editor.delete_template")
	if delete_keymap then
		actions[1] = {
			key = delete_keymap.key[1],
			description = delete_keymap.label,
			callback = function(editor_context)
				vim.ui.input({
					prompt = string.format('Delete template "%s"? [y/N]: ', selected.name),
				}, function(confirm)
					if vim.trim(confirm or ""):lower() ~= "y" then
						return
					end

					if vim.fn.delete(selected.path) ~= 0 then
						on_done(string.format('Failed to delete template "%s"', selected.name))
						return
					end

					editor_context.close()
					on_done()
				end)
			end,
		}
	end
	markdown_editor.open({
		key = key,
		title = string.format(" Template: %s ", selected.name),
		initial_text = content,
		actions = actions,
		on_save = function(text)
			on_done(write(selected.path, text))
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

			local templates = list()
			if #templates == 0 then
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
	local templates = list()
	if #templates == 0 then
		notify.warn("No templates found", { vim_notify = true })
		return
	end

	pick("Apply template", templates, function(template)
		if template == nil then
			return
		end

		local content, read_err = read(template)
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

	save_as(description, function(saved_name, err, overwritten)
		if err then
			notify.error(err, { vim_notify = true })
		elseif saved_name then
			local action = overwritten and "Updated" or "Created"
			notify.info(action .. " template " .. saved_name, { vim_notify = true })
		end
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
