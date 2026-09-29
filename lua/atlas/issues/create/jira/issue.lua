local M = {}

local keymaps = require("atlas.core.keymaps")
local icons = require("atlas.ui.shared.icons")
local form = require("atlas.ui.popups.form")
local issue_helper = require("atlas.issues.create.jira.helper")
local users_api = require("atlas.providers.jira.users")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local templates = require("atlas.issues.templates")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local request_scope = require("atlas.core.requests")

---@class IssueEditorFields
---@field summary string
---@field description table|string|nil
---@field assignee AtlasUser|nil
---@field reporter AtlasUser|nil
---@field project string
---@field issue_key string|nil
---@field issue_type IssueType|nil

---@class IssueState
---@field layout AtlasFormLayout
---@field preview_mode boolean
---@field original_markdown string
---@field initial IssueEditorFields
---@field is_submitting boolean
---@field closed boolean
---@field requests AtlasRequestScope
---@field fields IssueEditorFields
---@field assignees AtlasUser[]|"loading"|nil
---@field issue_types IssueType[]|"loading"|nil
---@field current_user AtlasUser|nil
---@field current_user_loading boolean
---@field spinner SpinnerInstance|nil
---@field content_width integer
---@field on_submit fun(fields: IssueEditorFields, done: fun(ok: boolean, err: string|nil))|nil
---@field preview_fn (fun(markdown: string): string)|nil

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param state IssueState
local function get_title(state)
	return form.get_title(state.layout)
end

---@param state IssueState
local function get_description(state)
	return form.get_body(state.layout)
end

---@param state IssueState
---@return string
local function get_active_markdown_description(state)
	if state.preview_mode then
		return tostring(state.original_markdown or "")
	end
	return get_description(state)
end

---@param state IssueState
---@param markdown string
---@return boolean
local function set_description_markdown(state, markdown)
	if state.closed or not valid_buf(state.layout.editor_buf) then
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

---@param left { id?: string|number }|nil
---@param right { id?: string|number }|nil
local function same_id(left, right)
	return (left and left.id) == (right and right.id)
end

---@param state IssueState
local function is_modified(state)
	local fields, initial = state.fields, state.initial
	local description = type(initial.description) == "string" and initial.description or ""
	return vim.trim(get_title(state)) ~= vim.trim(initial.summary or "")
		or get_active_markdown_description(state) ~= description
		or not same_id(fields.assignee, initial.assignee)
		or not same_id(fields.reporter or state.current_user, initial.reporter or state.current_user)
		or not same_id(fields.issue_type, initial.issue_type)
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

---@param state IssueState
local function meta_rows(state)
	return issue_helper.meta_rows(
		state.fields,
		state.assignees,
		state.issue_types,
		state.fields.reporter or state.current_user,
		state.current_user_loading,
		state.spinner
	)
end

---@param state IssueState
local function render_meta(state)
	if state.closed then
		return
	end
	form.render_meta(state, meta_rows(state))
end

---@param state IssueState
local function stop_loading_spinner_if_done(state)
	if not state.spinner then
		return
	end

	if state.assignees == "loading" or state.issue_types == "loading" or state.current_user_loading then
		return
	end

	state.spinner:stop()
	state.spinner = nil
end

---@param state IssueState
local function close_ui(state)
	if state.closed then
		return
	end
	state.closed = true
	state.requests.cancel()
	if state.spinner then
		state.spinner:stop()
		state.spinner = nil
	end
	form.close(state.layout)
end

---@param state IssueState
local function confirm_close(state)
	if not is_modified(state) then
		close_ui(state)
		return
	end

	vim.ui.input({
		prompt = "Discard changes? [y/N]: ",
	}, function(input)
		if input == nil then
			return
		end

		if vim.trim(tostring(input)):lower() == "y" then
			close_ui(state)
		end
	end)
end

---@param state IssueState
local function submit_issue(state)
	if state.closed or state.is_submitting then
		return
	end
	local title = vim.trim(get_title(state))
	local desc = state.preview_mode and state.original_markdown or get_description(state)

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

	state.is_submitting = true
	state.requests.run(function(done)
		on_submit(fields, done)
	end, function(ok, err)
		vim.schedule(function()
			if state.closed then
				return
			end
			state.is_submitting = false
			if ok then
				close_ui(state)
				return
			end

			form.notify(
				"error",
				err and err ~= "" and err or (is_edit and "Save issue failed" or "Create issue failed")
			)
		end)
	end)
end

---@param state IssueState
local function toggle_preview(state)
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
		state.original_markdown = get_description(state)
		local preview = state.preview_fn(state.original_markdown)
		vim.api.nvim_set_option_value("modifiable", true, { buf = state.layout.editor_buf })
		form.set_body(state.layout, preview)
		vim.api.nvim_set_option_value("modifiable", false, { buf = state.layout.editor_buf })
		vim.api.nvim_set_option_value("filetype", "json", { buf = state.layout.editor_buf })
		state.preview_mode = true
		form.notify("info", "Preview (read-only)")
	end
end

---@param state IssueState
local function show_assignee_picker(state)
	---@type table[]
	local initial_items = {}

	table.insert(initial_items, {
		id = "__unassign__",
		label = "Unassign",
		value = { id = nil, name = "Unassign" },
	})

	if state.assignees and state.assignees ~= "loading" then
		for _, user in ipairs(state.assignees) do
			table.insert(initial_items, {
				id = user.id or "",
				label = user.name or "",
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
			return state.requests.run(function(on_done)
				return issues_api.get_assignable_users(
					{ project = state.fields.project, issue_key = state.fields.issue_key },
					query,
					on_done
				)
			end, function(users, err)
				if err then
					done(nil, err)
					return
				end
				local items = {}
				table.insert(items, {
					id = "__unassign__",
					label = "Unassign",
					value = { id = nil, name = "Unassign" },
				})
				for _, u in ipairs(users or {}) do
					table.insert(items, {
						id = u.id or "",
						label = u.name or "",
						value = u,
					})
				end
				done(items, nil)
			end)
		end,
		on_select = function(item)
			if state.closed then
				return
			end
			if item.id == "__unassign__" then
				state.fields.assignee = nil
			else
				state.fields.assignee = item.value
			end
			render_meta(state)
		end,
	})
end

---@param state IssueState
local function show_reporter_picker(state)
	---@type table[]
	local initial_items = {}

	if state.assignees and state.assignees ~= "loading" then
		for _, user in ipairs(state.assignees) do
			table.insert(initial_items, {
				id = user.id or "",
				label = user.name or "",
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
			return state.requests.run(function(on_done)
				return issues_api.get_assignable_users(
					{ project = state.fields.project, issue_key = state.fields.issue_key },
					query,
					on_done
				)
			end, function(users, err)
				if err then
					done(nil, err)
					return
				end
				local items = {}
				for _, u in ipairs(users or {}) do
					table.insert(items, {
						id = u.id or "",
						label = u.name or "",
						value = u,
					})
				end
				done(items, nil)
			end)
		end,
		on_select = function(item)
			if state.closed then
				return
			end
			state.current_user_loading = false
			state.fields.reporter = item.value
			stop_loading_spinner_if_done(state)
			render_meta(state)
		end,
	})
end

---@param state IssueState
local function show_issue_type_picker(state)
	if state.issue_types == "loading" then
		form.notify("info", "Issue types are still loading")
		return
	end

	picker.select({
		title = "Select Issue Type",
		items = state.issue_types or {},
		format_item = function(issue_type)
			local icon, icon_hl = icons.issues_type(issue_type.name)
			return string.format("%s %s", icon, issue_type.name), icon_hl
		end,
		on_select = function(issue_type)
			if state.closed or not issue_type then
				return
			end
			state.fields.issue_type = issue_type
			render_meta(state)
		end,
	})
end

---@param on_submit fun(fields: IssueEditorFields, done: fun(ok: boolean, err: string|nil))|nil
---@param opts IssueEditorFields
---@param editor_opts { preview_fn: (fun(markdown: string): string)|nil, current_user: AtlasUser|nil }|nil
function M.open(on_submit, opts, editor_opts)
	---@type IssueState
	local state = {
		layout = {},
		preview_mode = false,
		original_markdown = "",
		fields = vim.deepcopy(opts),
		initial = vim.deepcopy(opts),
		is_submitting = false,
		closed = false,
		requests = request_scope.new(),
		content_width = 0,
		on_submit = on_submit,
		preview_fn = editor_opts and editor_opts.preview_fn or nil,
		current_user = editor_opts and editor_opts.current_user or nil,
		current_user_loading = false,
	}
	state.current_user_loading = state.fields.reporter == nil and state.current_user == nil
	local initial_desc = type(state.fields.description) == "string" and state.fields.description or ""
	local preview_keys = keymaps.resolve("ui.toggle_description_mode")

	form.open(state, {
		title_label = "Summary",
		body_label = "Description",
		initial_title = tostring(state.fields.summary or ""),
		initial_body = initial_desc,
		close = function()
			confirm_close(state)
		end,
		submit = function()
			submit_issue(state)
		end,
		meta = function()
			return meta_rows(state)
		end,
		keymaps = {
			{
				key = "ga",
				buffers = { "editor" },
				action = function()
					show_assignee_picker(state)
				end,
				desc = "assignee",
			},
			{
				key = "gr",
				buffers = { "editor" },
				action = function()
					show_reporter_picker(state)
				end,
				desc = "reporter",
			},
			{
				key = "gt",
				buffers = { "editor" },
				action = function()
					show_issue_type_picker(state)
				end,
				desc = "issue type",
			},
			{
				key = "gT",
				buffers = { "editor" },
				action = function()
					templates.open({
						get_description = function()
							return get_active_markdown_description(state)
						end,
						set_description = function(markdown)
							return set_description_markdown(state, markdown)
						end,
					})
				end,
				desc = "templates",
			},
			preview_keys and {
				key = preview_keys,
				buffers = { "editor" },
				action = function()
					toggle_preview(state)
				end,
				desc = "raw preview",
			} or nil,
		},
	})

	state.assignees = "loading"
	state.issue_types = "loading"
	state.spinner = spinner.create({
		on_tick = function()
			if state.assignees == "loading" or state.issue_types == "loading" or state.current_user_loading then
				render_meta(state)
			end
		end,
	})
	state.spinner:start()

	render_meta(state)

	if state.current_user_loading then
		state.requests.run(users_api.fetch_user, function(user, err)
			if not state.current_user_loading then
				return
			end
			state.current_user_loading = false
			if err then
				form.notify("warn", "Failed to load reporter: " .. err, { timeout = 2000 })
			else
				state.current_user = user
			end
			stop_loading_spinner_if_done(state)
			vim.schedule(function()
				render_meta(state)
			end)
		end)
	end

	if state.fields.project ~= "" then
		state.requests.run(function(done)
			return issues_api.get_assignable_users(
				{ project = state.fields.project, issue_key = state.fields.issue_key },
				"",
				done
			)
		end, function(users, err)
			if err then
				form.notify("warn", "Failed to load assignees: " .. err, { timeout = 2000 })
				state.assignees = {}
			else
				state.assignees = users or {}
			end

			stop_loading_spinner_if_done(state)
			vim.schedule(function()
				render_meta(state)
			end)
		end)

		state.requests.run(function(done)
			return issues_api.get_create_meta(state.fields.project, done)
		end, function(issue_types, err)
			if err then
				form.notify("warn", "Failed to load issue types: " .. err, { timeout = 2000 })
				state.issue_types = {}
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
					state.initial.issue_type = vim.deepcopy(state.fields.issue_type)
				end
			end

			stop_loading_spinner_if_done(state)
			vim.schedule(function()
				render_meta(state)
			end)
		end)
	else
		state.assignees = {}
		state.issue_types = {}
		stop_loading_spinner_if_done(state)
		render_meta(state)
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(state.layout.editor_win),
		once = true,
		callback = function()
			close_ui(state)
		end,
	})
end

return M
