--TODO: Currently hardcoded to jira
local M = {}

local footer = require("atlas.ui.components.footer")
local icons = require("atlas.ui.shared.icons")
local editor = require("atlas.ui.popups.editor")
local issue_helper = require("atlas.issues.create.jira.helper")
local users_api = require("atlas.issues.providers.jira.api.users")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local template_store = require("atlas.issues.templates")
local spinner = require("atlas.ui.components.spinner")
local spinner_popup = require("atlas.ui.popups.spinner")
local async_picker = require("atlas.ui.components.async_picker")

---@class IssueEditorFields
---@field summary string
---@field description table|string|nil
---@field assignee IssueUser|nil
---@field reporter IssueUser|nil
---@field project string
---@field issue_key string|nil
---@field issue_type IssueType|nil

---@class IssueWindows
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil
---@field container_win integer|nil
---@field container_buf integer|nil

---@class IssueState
---@field layout IssueWindows
---@field preview_mode boolean
---@field original_markdown string
---@field fields IssueEditorFields
---@field assignees IssueUser[]|"loading"|nil
---@field issue_types IssueType[]|"loading"|nil
---@field spinner SpinnerInstance|nil
---@field assignees_handle { job_id: integer, cancel: fun() }|nil
---@field issue_types_handle { job_id: integer, cancel: fun() }|nil
---@field content_width integer
---@field on_submit fun(fields: IssueEditorFields, done: fun(ok: boolean, err: string|nil))|nil
---@field preview_fn (fun(markdown: string): string)|nil

local state = {
	layout = {
		title_buf = nil,
		title_win = nil,
		meta_buf = nil,
		meta_win = nil,
		desc_buf = nil,
		desc_win = nil,
		container_win = nil,
		container_buf = nil,
	},
	preview_mode = false,
	original_markdown = "",
	fields = {
		summary = "",
		description = nil,
		assignee = nil,
		reporter = nil,
		project = "",
		issue_key = nil,
		issue_type = nil,
	},
	assignees = nil,
	issue_types = nil,
	spinner = nil,
	assignees_handle = nil,
	issue_types_handle = nil,
	content_width = 0,
	on_submit = nil,
	preview_fn = nil,
}

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function get_title()
	if not valid_buf(state.layout.title_buf) then
		return ""
	end
	local lines = vim.api.nvim_buf_get_lines(state.layout.title_buf, 0, -1, false)
	return table.concat(lines, " ")
end

local function get_description()
	if not valid_buf(state.layout.desc_buf) then
		return ""
	end
	local lines = vim.api.nvim_buf_get_lines(state.layout.desc_buf, 0, -1, false)
	return table.concat(lines, "\n")
end

---@return string
local function get_active_markdown_description()
	if state.preview_mode then
		return tostring(state.original_markdown or "")
	end
	return get_description()
end

---@param markdown string
---@return boolean
local function set_description_markdown(markdown)
	if not valid_buf(state.layout.desc_buf) then
		return false
	end

	local text = tostring(markdown or "")
	local lines = vim.split(text, "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = state.layout.desc_buf })
	vim.api.nvim_buf_set_lines(state.layout.desc_buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = state.layout.desc_buf })

	state.preview_mode = false
	state.original_markdown = text
	return true
end

local function is_modified()
	local title = vim.trim(get_title())
	local desc = vim.trim(get_description())
	return title ~= "" or desc ~= ""
end

---@param issue_types IssueType[]
---@return IssueType|nil
local function pick_default_issue_type(issue_types)
	for _, issue_type in ipairs(issue_types) do
		if tostring(issue_type.name or ""):lower() == "task" then
			return issue_type
		end
	end
	return issue_types[1]
end

local function meta_rows()
	return issue_helper.meta_rows(state.fields, state.assignees, state.issue_types, state.spinner)
end

local function render_meta()
	editor.render_meta(state, meta_rows())
end

local function stop_loading_spinner_if_done()
	if not state.spinner then
		return
	end

	if state.assignees == "loading" or state.issue_types == "loading" then
		return
	end

	state.spinner:stop()
	state.spinner = nil
end

local function cancel_pending_requests()
	if state.assignees_handle and state.assignees_handle.cancel then
		pcall(state.assignees_handle.cancel)
	end
	state.assignees_handle = nil

	if state.issue_types_handle and state.issue_types_handle.cancel then
		pcall(state.issue_types_handle.cancel)
	end
	state.issue_types_handle = nil
end

local function close_ui()
	cancel_pending_requests()
	spinner_popup.stop()

	if state.spinner then
		state.spinner:stop()
		state.spinner = nil
	end

	editor.close(state.layout)

	state.layout = {
		title_buf = nil,
		title_win = nil,
		meta_buf = nil,
		meta_win = nil,
		desc_buf = nil,
		desc_win = nil,
		container_win = nil,
		container_buf = nil,
	}
	state.preview_mode = false
	state.original_markdown = ""
	state.fields = {
		summary = "",
		description = nil,
		assignee = nil,
		reporter = nil,
		project = "",
		issue_key = nil,
		issue_type = nil,
	}
	state.assignees = nil
	state.issue_types = nil
	state.assignees_handle = nil
	state.issue_types_handle = nil
	state.content_width = 0
	state.on_submit = nil
	state.preview_fn = nil
end

local function confirm_close()
	if not is_modified() then
		close_ui()
		return
	end

	vim.ui.input({
		prompt = "Discard changes? [y/N]: ",
	}, function(input)
		if input == nil then
			return
		end

		if vim.trim(tostring(input)):lower() == "y" then
			close_ui()
		end
	end)
end

local function apply_template_from_picker()
	local templates, list_err = template_store.list()
	if list_err then
		footer.notify("error", list_err)
		return
	end

	if templates == nil or #templates == 0 then
		footer.notify("warn", "No templates found")
		return
	end

	vim.ui.select(templates, {
		prompt = "Apply template",
		kind = "atlas_jira_templates",
		format_item = function(item)
			return tostring((item and item.name) or "")
		end,
	}, function(selected)
		if selected == nil then
			return
		end

		local template_name = tostring(selected.name or "")
		if template_name == "" then
			footer.notify("warn", "Invalid template selected")
			return
		end

		local template_content, read_err = template_store.read(template_name)
		if read_err then
			footer.notify("error", read_err)
			return
		end

		local function apply_selected_template()
			if not set_description_markdown(template_content or "") then
				footer.notify("error", "Issue description buffer is not available")
				return
			end
			footer.notify("success", string.format("Applied template: %s", template_name), 1200)
		end

		if vim.trim(get_active_markdown_description()) == "" then
			apply_selected_template()
			return
		end

		vim.ui.input({
			prompt = "Description is not empty. Replace with template? [y/N]: ",
		}, function(input)
			if input and vim.trim(tostring(input)):lower() == "y" then
				apply_selected_template()
			end
		end)
	end)
end

local function save_description_as_template()
	local markdown = vim.trim(get_active_markdown_description())
	if markdown == "" then
		footer.notify("warn", "Description is empty")
		return
	end

	vim.ui.input({ prompt = "Template name: " }, function(input)
		if input == nil then
			return
		end

		local name = vim.trim(tostring(input))
		if name == "" then
			footer.notify("warn", "Template name is required")
			return
		end

		local ok, write_err, existed, normalized_name = template_store.write(name, markdown, { overwrite = false })
		if ok then
			footer.notify("success", string.format("Created template %s", tostring(normalized_name or name)), 1200)
			return
		end

		if existed then
			vim.ui.input({
				prompt = string.format('Template "%s" exists. Overwrite? [y/N]: ', tostring(normalized_name or name)),
			}, function(confirm)
				if confirm == nil or vim.trim(tostring(confirm)):lower() ~= "y" then
					return
				end
				local overwrite_ok, overwrite_err, _, final_name =
					template_store.write(name, markdown, { overwrite = true })
				if not overwrite_ok then
					footer.notify("error", overwrite_err or "Failed to overwrite template")
					return
				end
				footer.notify("success", string.format("Updated template %s", tostring(final_name or normalized_name or name)), 1200)
			end)
			return
		end

		footer.notify("error", write_err or "Failed to create template")
	end)
end

local function open_templates_menu()
	local items = {
		{ id = "apply", label = "Apply template" },
		{ id = "save", label = "Save current description as template" },
	}

	vim.ui.select(items, {
		prompt = "Issue templates",
		kind = "atlas_issue_templates_menu",
		format_item = function(item)
			return tostring((item and item.label) or "")
		end,
	}, function(selected)
		if selected == nil then
			return
		end

		if selected.id == "apply" then
			apply_template_from_picker()
			return
		end
		save_description_as_template()
	end)
end

local function submit_issue()
	local title = vim.trim(get_title())
	local desc = state.preview_mode and state.original_markdown or get_description()

	if title == "" then
		footer.notify("warn", "Title is required")
		return
	end

	local fields = vim.deepcopy(state.fields)
	fields.summary = title
	fields.description = desc ~= "" and desc or nil

	local on_submit = state.on_submit
	if not on_submit then
		return
	end

	local is_edit = type(state.fields.issue_key) == "string" and state.fields.issue_key ~= ""
	spinner_popup.start(is_edit and "Saving issue..." or "Creating issue...")

	on_submit(fields, function(ok, err)
		vim.schedule(function()
			spinner_popup.stop()

			if ok then
				close_ui()
				return
			end

			if err and err ~= "" then
				footer.notify("error", err)
			end
		end)
	end)
end

local function toggle_preview()
	if not valid_buf(state.layout.desc_buf) or not valid_win(state.layout.desc_win) then
		return
	end

	if not state.preview_fn then
		footer.notify("warn", "Preview not available")
		return
	end

	if state.preview_mode then
		vim.api.nvim_set_option_value("modifiable", true, { buf = state.layout.desc_buf })
		local lines = vim.split(state.original_markdown, "\n", { plain = true })
		vim.api.nvim_buf_set_lines(state.layout.desc_buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("filetype", "markdown", { buf = state.layout.desc_buf })
		state.preview_mode = false
		footer.notify("info", "Editing markdown")
	else
		state.original_markdown = get_description()
		local preview = state.preview_fn(state.original_markdown)
		local lines = vim.split(preview, "\n", { plain = true })
		vim.api.nvim_set_option_value("modifiable", true, { buf = state.layout.desc_buf })
		vim.api.nvim_buf_set_lines(state.layout.desc_buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = state.layout.desc_buf })
		vim.api.nvim_set_option_value("filetype", "json", { buf = state.layout.desc_buf })
		state.preview_mode = true
		footer.notify("info", "Preview (read-only)")
	end
end

local function show_assignee_picker()
	---@type AsyncPickerItem[]
	local initial_items = {}

	table.insert(initial_items, {
		id = "__unassign__",
		label = "Unassign",
		value = { account_id = nil, display_name = "Unassign" },
	})

	if state.assignees and state.assignees ~= "loading" then
		for _, user in ipairs(state.assignees) do
			table.insert(initial_items, {
				id = user.account_id or "",
				label = user.display_name or "",
				value = user,
			})
		end
	end

	async_picker.open({
		title = "Select Assignee",
		prompt = "Search users",
		initial_items = initial_items,
		fetch_on_open = not (state.assignees and state.assignees ~= "loading" and #state.assignees > 0),
		debounce_ms = 250,
		cache_ttl_ms = 60000,
		identifier = "jira_users:" .. (state.fields.project or ""),
		format_item = function(item)
			if item.id == "__unassign__" then
				return item.label
			end
			return string.format("%s %s", icons.general("user"), item.label or "")
		end,
		fetch = function(ctx, done)
			users_api.get_assignable_users(
				{ project = state.fields.project, issue_key = state.fields.issue_key },
				ctx.query,
				function(users, err)
					if err then
						done(nil, err)
						return
					end
					local items = {}
					table.insert(items, {
						id = "__unassign__",
						label = "Unassign",
						value = { account_id = nil, display_name = "Unassign" },
					})
					for _, u in ipairs(users or {}) do
						table.insert(items, {
							id = u.account_id or "",
							label = u.display_name or "",
							value = u,
						})
					end
					done(items, nil)
				end
			)
		end,
		on_select = function(item)
			if item.id == "__unassign__" then
				state.fields.assignee = nil
			else
				state.fields.assignee = item.value
			end
			render_meta()
		end,
	})
end

local function show_reporter_picker()
	---@type AsyncPickerItem[]
	local initial_items = {}

	if state.assignees and state.assignees ~= "loading" then
		for _, user in ipairs(state.assignees) do
			table.insert(initial_items, {
				id = user.account_id or "",
				label = user.display_name or "",
				value = user,
			})
		end
	end

	async_picker.open({
		title = "Select Reporter",
		prompt = "Search users",
		initial_items = initial_items,
		fetch_on_open = not (state.assignees and state.assignees ~= "loading" and #state.assignees > 0),
		debounce_ms = 250,
		cache_ttl_ms = 60000,
		identifier = "jira_users:" .. (state.fields.project or ""),
		format_item = function(item)
			return string.format("%s %s", icons.general("user"), item.label or "")
		end,
		fetch = function(ctx, done)
			users_api.get_assignable_users(
				{ project = state.fields.project, issue_key = state.fields.issue_key },
				ctx.query,
				function(users, err)
					if err then
						done(nil, err)
						return
					end
					local items = {}
					for _, u in ipairs(users or {}) do
						table.insert(items, {
							id = u.account_id or "",
							label = u.display_name or "",
							value = u,
						})
					end
					done(items, nil)
				end
			)
		end,
		on_select = function(item)
			state.fields.reporter = item.value
			render_meta()
		end,
	})
end

local function show_issue_type_picker()
	---@type AsyncPickerItem[]
	local initial_items = {}

	if state.issue_types and state.issue_types ~= "loading" then
		for _, issue_type in ipairs(state.issue_types) do
			table.insert(initial_items, {
				id = tostring(issue_type.id or ""),
				label = tostring(issue_type.name or ""),
				value = issue_type,
			})
		end
	end

	async_picker.open({
		title = "Select Issue Type",
		prompt = "Filter types",
		initial_items = initial_items,
		fetch_on_open = not (state.issue_types and state.issue_types ~= "loading" and #state.issue_types > 0),
		debounce_ms = 0,
		identifier = "jira_issue_types:" .. (state.fields.project or ""),
		format_item = function(item)
			return string.format("%s %s", icons.issues_type(item.label), item.label)
		end,
		fetch = function(ctx, fetch_done)
			local function do_filter()
				if ctx.signal.cancelled then
					return
				end

				if state.issue_types == "loading" then
					vim.defer_fn(do_filter, 100)
					return
				end

				if #initial_items == 0 and state.issue_types then
					for _, issue_type in ipairs(state.issue_types) do
						table.insert(initial_items, {
							id = tostring(issue_type.id or ""),
							label = tostring(issue_type.name or ""),
							value = issue_type,
						})
					end
				end

				local query = vim.trim(ctx.query):lower()
				if query == "" then
					fetch_done(initial_items, nil)
					return
				end
				local filtered = {}
				for _, item in ipairs(initial_items) do
					if item.label:lower():find(query, 1, true) then
						table.insert(filtered, item)
					end
				end
				fetch_done(filtered, nil)
			end

			do_filter()
		end,
		on_select = function(item)
			state.fields.issue_type = item.value
			render_meta()
		end,
	})
end

---@param on_submit fun(fields: IssueEditorFields, done: fun(ok: boolean, err: string|nil))|nil
---@param opts IssueEditorFields
---@param editor_opts { preview_fn?: fun(markdown: string): string }|nil
function M.open(on_submit, opts, editor_opts)
	if valid_win(state.layout.container_win) then
		close_ui()
	end

	require("atlas.ui.shared.highlights").setup()
	require("atlas.issues.providers.jira.highlights").setup()

	state.on_submit = on_submit
	state.fields = opts
	state.preview_fn = editor_opts and editor_opts.preview_fn or nil
	state.assignees = nil
	state.issue_types = nil

	local is_edit = type(state.fields.issue_key) == "string" and state.fields.issue_key ~= ""
	local popup_title = is_edit and " Edit Issue " or " Create Issue "
	local initial_desc = type(state.fields.description) == "string" and state.fields.description or ""

	editor.open(state, {
		title = popup_title,
		min_height = 24,
		meta_height = 2,
		title_winbar = "Summary",
		desc_winbar = "Description",
		initial_title = tostring(state.fields.summary or ""),
		initial_body = initial_desc,
		close = confirm_close,
		submit = submit_issue,
		meta = meta_rows,
		keymaps = {
			{
				key = "ga",
				buffers = { "title", "desc" },
				action = show_assignee_picker,
				desc = "assignee",
				show_in_footer = true,
			},
			{
				key = "gr",
				buffers = { "title", "desc" },
				action = show_reporter_picker,
				desc = "reporter",
				show_in_footer = true,
			},
			{
				key = "gt",
				buffers = { "title", "desc" },
				action = show_issue_type_picker,
				desc = "issue type",
				show_in_footer = true,
			},
			{
				key = "gT",
				buffers = { "title", "meta", "desc" },
				action = open_templates_menu,
				desc = "templates",
				show_in_footer = true,
			},
			{
				key = "m",
				buffers = { "title", "meta", "desc" },
				action = toggle_preview,
				desc = "raw preview",
				show_in_footer = true,
			},
			{
				key = "<CR>",
				buffers = { "meta" },
				action = show_assignee_picker,
				desc = "assignee",
			},
		},
	})

	state.assignees = "loading"
	state.issue_types = "loading"
	state.spinner = spinner.create({
		on_tick = function()
			if state.assignees == "loading" or state.issue_types == "loading" then
				render_meta()
			end
		end,
	})
	state.spinner:start()

	render_meta()

	if state.fields.project ~= "" then
		state.assignees_handle = users_api.get_assignable_users(
			{ project = state.fields.project, issue_key = state.fields.issue_key },
			"",
			function(users, err)
				state.assignees_handle = nil

				if err then
					footer.notify("warn", "Failed to load assignees: " .. err, 2000)
					state.assignees = {}
				else
					state.assignees = users or {}
				end

				stop_loading_spinner_if_done()
				vim.schedule(function()
					render_meta()
				end)
			end
		)

		state.issue_types_handle = issues_api.get_create_meta(state.fields.project, function(issue_types, err)
			state.issue_types_handle = nil

			if err then
				footer.notify("warn", "Failed to load issue types: " .. err, 2000)
				state.issue_types = {}
				state.fields.issue_type = nil
			else
				local filtered = {}
				for _, issue_type in ipairs(issue_types or {}) do
					if not issue_type.subtask then
						table.insert(filtered, issue_type)
					end
				end
				state.issue_types = filtered
				if not state.fields.issue_type then
					state.fields.issue_type = pick_default_issue_type(state.issue_types)
				end
			end

			stop_loading_spinner_if_done()
			vim.schedule(function()
				render_meta()
			end)
		end)
	else
		state.assignees = {}
		state.issue_types = {}
		stop_loading_spinner_if_done()
		state.fields.issue_type = nil
		render_meta()
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(state.layout.container_win),
		once = true,
		callback = function()
			close_ui()
		end,
	})
end

return M
