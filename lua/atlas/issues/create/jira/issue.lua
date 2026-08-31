local M = {}

local icons = require("atlas.ui.shared.icons")
local form = require("atlas.ui.popups.form")
local issue_helper = require("atlas.issues.create.jira.helper")
local users_api = require("atlas.issues.providers.jira.api.users")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local templates = require("atlas.issues.templates")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")

---@class IssueEditorFields
---@field summary string
---@field description table|string|nil
---@field assignee IssueUser|nil
---@field reporter IssueUser|nil
---@field project string
---@field issue_key string|nil
---@field issue_type IssueType|nil

---@class IssueState
---@field layout AtlasFormLayout
---@field preview_mode boolean
---@field original_markdown string
---@field initial_summary string
---@field initial_description string
---@field fields IssueEditorFields
---@field assignees IssueUser[]|"loading"|nil
---@field issue_types IssueType[]|"loading"|nil
---@field current_user IssueUser|nil
---@field current_user_loading boolean
---@field spinner SpinnerInstance|nil
---@field assignees_handle { job_id: integer, cancel: fun() }|nil
---@field issue_types_handle { job_id: integer, cancel: fun() }|nil
---@field current_user_handle { job_id: integer, cancel: fun() }|nil
---@field content_width integer
---@field on_submit fun(fields: IssueEditorFields, done: fun(ok: boolean, err: string|nil))|nil
---@field preview_fn (fun(markdown: string): string)|nil

local state = {
	layout = {},
	preview_mode = false,
	original_markdown = "",
	initial_summary = "",
	initial_description = "",
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
	current_user = nil,
	current_user_loading = false,
	spinner = nil,
	assignees_handle = nil,
	issue_types_handle = nil,
	current_user_handle = nil,
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
	return form.get_title(state.layout)
end

local function get_description()
	return form.get_body(state.layout)
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
	if not valid_buf(state.layout.editor_buf) then
		return false
	end

	local text = tostring(markdown or "")
	vim.api.nvim_set_option_value("modifiable", true, { buf = state.layout.editor_buf })
	form.set_body(state.layout, text)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = state.layout.editor_buf })

	state.preview_mode = false
	state.original_markdown = text
	return true
end

local function is_modified()
	return vim.trim(get_title()) ~= vim.trim(state.initial_summary)
		or get_active_markdown_description() ~= state.initial_description
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
	return issue_helper.meta_rows(
		state.fields,
		state.assignees,
		state.issue_types,
		state.fields.reporter or state.current_user,
		state.current_user_loading,
		state.spinner
	)
end

local function render_meta()
	form.render_meta(state, meta_rows())
end

local function stop_loading_spinner_if_done()
	if not state.spinner then
		return
	end

	if state.assignees == "loading" or state.issue_types == "loading" or state.current_user_loading then
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

	if state.current_user_handle and state.current_user_handle.cancel then
		pcall(state.current_user_handle.cancel)
	end
	state.current_user_handle = nil
end

local function close_ui()
	cancel_pending_requests()

	if state.spinner then
		state.spinner:stop()
		state.spinner = nil
	end

	form.close(state.layout)

	state.layout = {}
	state.preview_mode = false
	state.original_markdown = ""
	state.initial_summary = ""
	state.initial_description = ""
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
	state.current_user = nil
	state.current_user_loading = false
	state.assignees_handle = nil
	state.issue_types_handle = nil
	state.current_user_handle = nil
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

local function submit_issue()
	local title = vim.trim(get_title())
	local desc = state.preview_mode and state.original_markdown or get_description()

	if title == "" then
		form.notify("warn", "Title is required")
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
	form.notify("loading", is_edit and "Saving issue..." or "Creating issue...")

	on_submit(fields, function(ok, err)
		vim.schedule(function()
			if ok then
				close_ui()
				return
			end

			form.notify(
				"error",
				err and err ~= "" and err or (is_edit and "Save issue failed" or "Create issue failed")
			)
		end)
	end)
end

local function toggle_preview()
	if not valid_buf(state.layout.editor_buf) or not valid_win(state.layout.editor_win) then
		return
	end

	if not state.preview_fn then
		form.notify("warn", "Preview not available")
		return
	end

	if state.preview_mode then
		vim.api.nvim_set_option_value("modifiable", true, { buf = state.layout.editor_buf })
		form.set_body(state.layout, state.original_markdown)
		vim.api.nvim_set_option_value("filetype", "markdown", { buf = state.layout.editor_buf })
		state.preview_mode = false
		form.notify("info", "Editing markdown")
	else
		state.original_markdown = get_description()
		local preview = state.preview_fn(state.original_markdown)
		vim.api.nvim_set_option_value("modifiable", true, { buf = state.layout.editor_buf })
		form.set_body(state.layout, preview)
		vim.api.nvim_set_option_value("modifiable", false, { buf = state.layout.editor_buf })
		vim.api.nvim_set_option_value("filetype", "json", { buf = state.layout.editor_buf })
		state.preview_mode = true
		form.notify("info", "Preview (read-only)")
	end
end

local function show_assignee_picker()
	---@type table[]
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

	picker.search({
		title = "Select Assignee",
		initial_items = initial_items,
		fetch_on_open = not (state.assignees and state.assignees ~= "loading" and #state.assignees > 0),
		format_item = function(item)
			if item.id == "__unassign__" then
				return item.label
			end
			return string.format("%s %s", icons.general("user"), item.label or "")
		end,
		fetch = function(query, done)
			return users_api.get_assignable_users(
				{ project = state.fields.project, issue_key = state.fields.issue_key },
				query,
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
	---@type table[]
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

	picker.search({
		title = "Select Reporter",
		initial_items = initial_items,
		fetch_on_open = not (state.assignees and state.assignees ~= "loading" and #state.assignees > 0),
		format_item = function(item)
			return string.format("%s %s", icons.general("user"), item.label or "")
		end,
		fetch = function(query, done)
			return users_api.get_assignable_users(
				{ project = state.fields.project, issue_key = state.fields.issue_key },
				query,
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
			if state.current_user_handle then
				state.current_user_handle.cancel()
				state.current_user_handle = nil
			end
			state.current_user_loading = false
			if state.current_user and item.value.account_id == state.current_user.account_id then
				state.fields.reporter = nil
			else
				state.fields.reporter = item.value
			end
			stop_loading_spinner_if_done()
			render_meta()
		end,
	})
end

local function show_issue_type_picker()
	---@type table[]
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

	picker.search({
		title = "Select Issue Type",
		initial_items = initial_items,
		fetch_on_open = not (state.issue_types and state.issue_types ~= "loading" and #state.issue_types > 0),
		debounce_ms = 0,
		format_item = function(item)
			local icon, icon_hl = icons.issues_type(item.label)
			return string.format("%s %s", icon, item.label), icon_hl
		end,
		fetch = function(query, fetch_done)
			local cancelled = false
			local function do_filter()
				if cancelled then
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

				local normalized = vim.trim(query):lower()
				if normalized == "" then
					fetch_done(initial_items, nil)
					return
				end
				local filtered = {}
				for _, item in ipairs(initial_items) do
					if item.label:lower():find(normalized, 1, true) then
						table.insert(filtered, item)
					end
				end
				fetch_done(filtered, nil)
			end

			do_filter()
			return {
				cancel = function()
					cancelled = true
				end,
			}
		end,
		on_select = function(item)
			state.fields.issue_type = item.value
			render_meta()
		end,
	})
end

---@param on_submit fun(fields: IssueEditorFields, done: fun(ok: boolean, err: string|nil))|nil
---@param opts IssueEditorFields
---@param editor_opts { preview_fn: (fun(markdown: string): string)|nil, current_user: IssueUser|nil }|nil
function M.open(on_submit, opts, editor_opts)
	if valid_win(state.layout.editor_win) then
		close_ui()
	end

	require("atlas.issues.ui.highlights").setup()

	state.on_submit = on_submit
	state.fields = opts
	state.preview_fn = editor_opts and editor_opts.preview_fn or nil
	state.assignees = nil
	state.issue_types = nil
	state.current_user = editor_opts and editor_opts.current_user or nil
	state.current_user_loading = state.fields.reporter == nil and state.current_user == nil

	local initial_desc = type(state.fields.description) == "string" and state.fields.description or ""
	state.initial_summary = tostring(state.fields.summary or "")
	state.initial_description = initial_desc

	form.open(state, {
		title_label = "Summary",
		body_label = "Description",
		initial_title = tostring(state.fields.summary or ""),
		initial_body = initial_desc,
		close = confirm_close,
		submit = submit_issue,
		meta = meta_rows,
		keymaps = {
			{
				key = "ga",
				buffers = { "editor" },
				action = show_assignee_picker,
				desc = "assignee",
			},
			{
				key = "gr",
				buffers = { "editor" },
				action = show_reporter_picker,
				desc = "reporter",
			},
			{
				key = "gt",
				buffers = { "editor" },
				action = show_issue_type_picker,
				desc = "issue type",
			},
			{
				key = "gT",
				buffers = { "editor" },
				action = function()
					templates.open({
						get_description = get_active_markdown_description,
						set_description = set_description_markdown,
					})
				end,
				desc = "templates",
			},
			{
				key = "m",
				buffers = { "editor" },
				action = toggle_preview,
				desc = "raw preview",
			},
		},
	})

	state.assignees = "loading"
	state.issue_types = "loading"
	state.spinner = spinner.create({
		on_tick = function()
			if state.assignees == "loading" or state.issue_types == "loading" or state.current_user_loading then
				render_meta()
			end
		end,
	})
	state.spinner:start()

	render_meta()

	if state.current_user_loading then
		state.current_user_handle = users_api.get_myself(function(user, err)
			state.current_user_handle = nil
			state.current_user_loading = false
			if err then
				form.notify("warn", "Failed to load reporter: " .. err, { timeout = 2000 })
			else
				state.current_user = user
			end
			stop_loading_spinner_if_done()
			vim.schedule(function()
				render_meta()
			end)
		end)
	end

	if state.fields.project ~= "" then
		state.assignees_handle = users_api.get_assignable_users(
			{ project = state.fields.project, issue_key = state.fields.issue_key },
			"",
			function(users, err)
				state.assignees_handle = nil

				if err then
					form.notify("warn", "Failed to load assignees: " .. err, { timeout = 2000 })
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
				form.notify("warn", "Failed to load issue types: " .. err, { timeout = 2000 })
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
		pattern = tostring(state.layout.editor_win),
		once = true,
		callback = function()
			close_ui()
		end,
	})
end

return M
