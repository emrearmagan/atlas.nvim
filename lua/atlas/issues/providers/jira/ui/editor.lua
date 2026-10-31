local M = {}

local config = require("atlas.config")
local form = require("atlas.ui.form")
local issues = require("atlas.issues.providers.jira.api.issues")
local service = require("atlas.providers.jira.client")
local users = require("atlas.providers.jira.users")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local requests = require("atlas.core.requests")
local keymaps = require("atlas.core.keymaps")
local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.issues.ui.presentation")
local field_input = require("atlas.issues.providers.jira.ui.field_input")
local adf = require("atlas.formats.adf.from_markdown")

---@class JiraIssueEditorResult
---@field key string
---@field id string|nil
---@field self string|nil

---@class JiraIssueEditorValues
---@field title string
---@field body string
---@field assignee string|false
---@field reporter string|false
---@field issue_type string|false
---@field fields table<string, JiraFieldValue>

---@class JiraIssueEditorState
---@field project_key string
---@field issue JiraIssue|nil
---@field on_done (fun(result: JiraIssueEditorResult|nil, err: string|nil))|nil
---@field assignee AtlasUser|nil
---@field reporter AtlasUser|nil
---@field issue_type IssueType|nil
---@field fields table<string, JiraFieldValue>
---@field meta_fields table<string, JiraMetaField>|nil
---@field sprints { id: string, name: string }[]|nil
---@field defaults AtlasJiraProjectDefaultsConfig
---@field raw_description table|string|nil
---@field initial JiraIssueEditorValues
---@field requests AtlasRequestScope
---@field loading { assignee?: boolean, reporter?: boolean, type?: boolean, fields?: boolean, sprints?: boolean }
---@field submitting boolean

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@return JiraIssueEditorValues
local function values(state, editor)
	local content = form.get_content(editor)
	return {
		title = vim.trim(content.title),
		body = content.body,
		assignee = state.assignee and state.assignee.id or false,
		reporter = state.reporter and state.reporter.id or false,
		issue_type = state.issue_type and state.issue_type.id or false,
		fields = state.fields,
	}
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@return boolean
local function is_modified(state, editor)
	return not vim.deep_equal(values(state, editor), state.initial)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@return boolean
local function content_modified(state, editor)
	local current = values(state, editor)
	return current.title ~= state.initial.title or current.body ~= state.initial.body
end

---@param state JiraIssueEditorState
---@param body string
---@return table|string|userdata
local function description(state, body)
	if body == state.initial.body and state.raw_description then
		return state.raw_description
	elseif body == "" then
		return vim.NIL
	end

	return service.is_server() and body or adf.to_adf(body)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function render_loading(state, editor)
	form.render_meta(editor)
	if not state.submitting and editor.statusline.loading_spinner then
		local pending = next(state.loading)
		if pending then
			editor.statusline:notify("loading", "Loading " .. pending .. "...")
		else
			editor.statusline:clear_notice()
		end
	end
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param field "assignee"|"reporter"
local function select_user(state, editor, field)
	if state.submitting or state.loading[field] then
		return
	end

	local unassigned = { id = "__unassigned__", name = "None" }
	picker.search({
		title = field == "assignee" and "Assignee" or "Reporter",
		format_item = function(user)
			return user.name
		end,
		fetch = function(query, done)
			state.loading[field] = true
			editor.statusline:notify("loading", "Loading " .. field .. "...")
			form.render_meta(editor)

			return state.requests.run(function(callback)
				return issues.get_assignable_users({
					project = state.project_key,
					issue_key = state.issue and state.issue.key,
				}, query, callback)
			end, function(items, err)
				state.loading[field] = nil
				if err and not state.submitting then
					editor.statusline:notify("error", err)
				end
				render_loading(state, editor)

				if items and field == "assignee" then
					items = vim.list_extend({ unassigned }, items)
				end
				done(items, err)
			end)
		end,
		on_select = function(user)
			state.loading[field] = nil
			if not editor.closed and not state.submitting then
				state[field] = user ~= unassigned and user or nil
				render_loading(state, editor)
			end
		end,
		on_cancel = function()
			state.loading[field] = nil
			render_loading(state, editor)
		end,
	})
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param fields table<string, JiraMetaField>|nil
---@param err string|nil
---@param on_loaded (fun())|nil
local function apply_fields(state, editor, fields, err, on_loaded)
	state.loading.fields = nil
	if fields then
		local handled = {
			summary = true,
			description = true,
			issuetype = true,
			project = true,
			assignee = true,
			reporter = true,
		}
		state.meta_fields = {}
		for field_id, field in pairs(fields) do
			if field.kind and not handled[field_id] then
				state.meta_fields[field_id] = field
				state.fields[field_id] = field.initial
			end
		end
		state.initial.fields = vim.tbl_extend("force", {}, state.fields)
	end
	render_loading(state, editor)

	if state.submitting then
		return
	elseif not fields then
		editor.statusline:notify("error", err or "Unable to load fields")
	elseif on_loaded then
		on_loaded()
	end
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param on_loaded (fun())|nil
local function load_create_fields(state, editor, on_loaded)
	local issue_type = assert(state.issue_type)
	state.loading.fields = true
	editor.statusline:notify("loading", "Loading fields...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.get_create_fields(state.project_key, issue_type.id, done)
	end, function(fields, err)
		if state.issue_type ~= issue_type then
			return
		end

		for field_id, value in pairs(state.defaults.fields or {}) do
			local field = fields and fields[field_id]
			if field and field.kind then
				local initial = field_input.from_config(field, value)
				if not initial then
					notify.warn("Invalid default for " .. field.name)
				end
				field.initial = initial or field.initial
			end
		end
		apply_fields(state, editor, fields, err, on_loaded)
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param on_loaded (fun())|nil
local function load_edit_fields(state, editor, on_loaded)
	local issue = assert(state.issue)
	state.loading.fields = true
	editor.statusline:notify("loading", "Loading fields...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.get_edit_fields(issue.key, done)
	end, function(fields, err)
		apply_fields(state, editor, fields, err, on_loaded)
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param on_selected (fun())|nil
local function select_issue_type(state, editor, on_selected)
	if state.submitting or state.loading.type then
		return
	end

	state.loading.type = true
	editor.statusline:notify("loading", "Loading issue types...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.get_issue_types(state.project_key, done)
	end, function(items, err)
		state.loading.type = nil
		if state.submitting then
			form.render_meta(editor)
			return
		end

		if err or not items then
			editor.statusline:notify("error", err or "Unable to load issue types")
			render_loading(state, editor)
			return
		end

		local subtask = state.issue_type and state.issue_type.subtask or false
		items = vim.tbl_filter(function(item)
			return item.subtask == subtask
		end, items)

		render_loading(state, editor)

		picker.select({
			title = "Issue type",
			items = items,
			format_item = function(item)
				local icon = (item.icon and item.icon.icon or icons.get("issue")) .. " "
				return icon .. item.name, { { icon, item.icon and item.icon.hl_group }, { item.name } }
			end,
			on_select = function(item)
				local changed = item and (not state.issue_type or state.issue_type.id ~= item.id)
				if changed and not editor.closed and not state.submitting then
					state.issue_type = item
					if state.issue then
						form.render_meta(editor)
					else
						state.fields = {}
						state.meta_fields = nil
						load_create_fields(state, editor, on_selected)
					end
				end
			end,
		})
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function load_default_type(state, editor)
	state.loading.type = true
	editor.statusline:notify("loading", "Loading issue types...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.get_issue_types(state.project_key, done)
	end, function(items, err)
		state.loading.type = nil
		local name = state.defaults.issue_type:lower()
		for _, item in ipairs(items or {}) do
			if item.name:lower() == name then
				state.issue_type = item
			end
		end
		render_loading(state, editor)

		if state.submitting then
			return
		elseif state.issue_type then
			load_create_fields(state, editor)
		else
			editor.statusline:notify("error", err or ("Unknown issue type " .. state.defaults.issue_type))
		end
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function load_reporter(state, editor)
	state.loading.reporter = true
	editor.statusline:notify("loading", "Loading reporter...")
	form.render_meta(editor)

	state.requests.run(users.fetch_user, function(user, err)
		state.loading.reporter = nil
		if err then
			editor.statusline:notify("error", err)
		else
			state.reporter = user
			state.initial.reporter = user and user.id or false
		end
		render_loading(state, editor)
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param on_loaded fun()
local function load_sprints(state, editor, on_loaded)
	state.loading.sprints = true
	editor.statusline:notify("loading", "Loading sprints...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.get_sprints(state.project_key, done)
	end, function(sprints, err)
		state.loading.sprints = nil
		state.sprints = sprints
		render_loading(state, editor)

		if state.submitting then
			return
		elseif not sprints then
			editor.statusline:notify("error", err or "Unable to load sprints")
		else
			on_loaded()
		end
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param field_id string
---@param field JiraMetaField
local function edit_field(state, editor, field_id, field)
	if field.kind == "sprint" and not state.sprints then
		load_sprints(state, editor, function()
			edit_field(state, editor, field_id, field)
		end)
		return
	elseif field.kind == "sprint" then
		field.options = state.sprints
	end

	field_input.edit(field_id, field, state.fields[field_id], function(value)
		if not editor.closed and not state.submitting then
			state.fields[field_id] = value
			form.render_meta(editor)
		end
	end, function(err)
		editor.statusline:notify("error", err)
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function select_field(state, editor)
	if state.submitting or state.loading.fields or state.loading.sprints then
		return
	elseif not state.issue_type then
		select_issue_type(state, editor, function()
			select_field(state, editor)
		end)
		return
	elseif not state.meta_fields and state.issue then
		load_edit_fields(state, editor, function()
			select_field(state, editor)
		end)
		return
	elseif not state.meta_fields then
		load_create_fields(state, editor, function()
			select_field(state, editor)
		end)
		return
	end

	field_input.select(state.meta_fields, state.fields, function(field_id, field)
		if not editor.closed and not state.submitting then
			edit_field(state, editor, field_id, field)
		end
	end)
end

---@param state JiraIssueEditorState
---@return AtlasFormMetaRow[]
local function render_meta(state)
	local type_name = state.issue_type and state.issue_type.name
	local type_style = state.issue_type and state.issue_type.icon
	local type_icon = type_style and type_style.icon or icons.get("issue")
	local type_hl = type_style and type_style.hl_group or "AtlasTextMuted"
	local assignee = state.assignee and presentation.person_name(state.assignee)
	local reporter = state.reporter and presentation.person_name(state.reporter)

	local rows = {
		{
			{
				key = "Project:",
				value = icons.provider_icon("jira", "issues") .. " " .. state.project_key,
				hl = "AtlasJiraKey",
			},
			{
				key = "Type*:",
				value = type_name and type_icon .. " " .. type_name or "None",
				hl = type_name and type_hl or "AtlasTextWarning",
				loading = state.loading.type,
			},
		},
		{
			{
				key = "Assignee:",
				value = icons.get("user") .. " " .. (assignee or "None"),
				hl = presentation.person_hl(assignee),
				loading = state.loading.assignee,
			},
			{
				key = "Reporter:",
				value = icons.get("user") .. " " .. (reporter or "None"),
				hl = presentation.person_hl(reporter),
				loading = state.loading.reporter,
			},
		},
	}

	local fields = {}
	for field_id, field in pairs(state.meta_fields or {}) do
		local current = state.fields[field_id]
		if current or field.required then
			local value, hl = field_input.display(field_id, field, current)
			table.insert(fields, { name = field.name, required = field.required, value = value, hl = hl })
		end
	end
	table.sort(fields, function(a, b)
		if a.required ~= b.required then
			return a.required
		end
		return a.name < b.name
	end)
	for i = 1, #fields, 2 do
		local row = {}
		for _, field in ipairs({ fields[i], fields[i + 1] }) do
			table.insert(row, {
				key = field.name .. (field.required and "*" or "") .. ":",
				value = field.value,
				hl = field.hl,
			})
		end
		table.insert(rows, row)
	end
	return rows
end

---@param state JiraIssueEditorState
---@param current JiraIssueEditorValues
---@return table
local function create_payload(state, current)
	local user_key = service.is_server() and "name" or "accountId"
	local fields = {
		project = { key = state.project_key },
		summary = current.title,
		description = description(state, current.body),
		issuetype = { id = current.issue_type },
	}
	if current.assignee ~= state.initial.assignee then
		fields.assignee = current.assignee and { [user_key] = current.assignee } or vim.NIL
	end
	if current.reporter ~= state.initial.reporter then
		fields.reporter = current.reporter and { [user_key] = current.reporter } or vim.NIL
	end
	for field_id, field in pairs(state.fields) do
		fields[field_id] = field.value
	end
	return fields
end

---@param state JiraIssueEditorState
---@param current JiraIssueEditorValues
---@return table
local function update_payload(state, current)
	local user_key = service.is_server() and "name" or "accountId"
	local fields = {
		summary = current.title,
		description = description(state, current.body),
		issuetype = { id = current.issue_type },
	}
	if current.assignee ~= state.initial.assignee then
		fields.assignee = current.assignee and { [user_key] = current.assignee } or vim.NIL
	end
	if current.reporter ~= state.initial.reporter then
		fields.reporter = current.reporter and { [user_key] = current.reporter } or vim.NIL
	end
	for field_id in pairs(state.meta_fields or {}) do
		local field = state.fields[field_id]
		if not vim.deep_equal(field, state.initial.fields[field_id]) then
			fields[field_id] = field and field.value or vim.NIL
		end
	end
	return fields
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function submit(state, editor)
	if state.submitting then
		return
	end

	local current = values(state, editor)
	if current.title == "" then
		notify.warn("Title is required")
		return
	elseif not current.issue_type then
		notify.warn("Issue type is required")
		return
	elseif not state.issue and next(state.loading) then
		return
	end

	if state.issue and not is_modified(state, editor) then
		form.close(editor)
		notify.info("No changes")
		return
	end

	state.submitting = true
	vim.bo[editor.editor_buf].modifiable = false
	editor.statusline:notify("loading", state.issue and "Saving issue..." or "Creating issue...")

	---@param result JiraIssueEditorResult|nil
	---@param err string|nil
	local function done(result, err)
		editor.statusline:clear_notice()
		if not result then
			err = err or "Unable to save issue"
			state.submitting = false
			if not editor.closed then
				vim.bo[editor.editor_buf].modifiable = true
				editor.statusline:notify("error", err)
			else
				if state.on_done then
					state.on_done(nil, err)
				end
				notify.error(err)
			end
			return
		end

		local was_closed = editor.closed
		form.close(editor)
		state.submitting = false
		if state.on_done then
			state.on_done(result, nil)
		end

		notify.info((state.issue and "Updated " or "Created ") .. result.key, { vim_notify = true })
		if not state.issue and not was_closed then
			require("atlas.commands.open").open(result.key)
		end
	end

	if state.issue then
		issues.update_issue(state.issue.key, update_payload(state, current), function(ok, err)
			done(ok and { key = state.issue.key } or nil, err)
		end)
		return
	end

	issues.create_issue(create_payload(state, current), done)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function close(state, editor)
	if state.submitting then
		return
	elseif not content_modified(state, editor) then
		form.close(editor)
	else
		vim.ui.input({ prompt = "Discard issue changes? [y/N]: " }, function(answer)
			if not state.submitting and (answer or ""):lower() == "y" then
				form.close(editor)
			end
		end)
	end
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function preview_description(state, editor)
	local content = description(state, form.get_content(editor).body)
	local text = type(content) == "string" and content or require("atlas.ui.shared.utils").encode_pretty_json(content)
	vim.lsp.util.open_floating_preview(
		vim.split(text, "\n", { plain = true }),
		service.is_server() and "text" or "json",
		{
			border = "rounded",
			focus_id = "atlas_jira_description",
		}
	)
end

---@param project_key string
---@param issue JiraIssue|nil
---@param details JiraIssueDetails|nil
---@param on_done (fun(result: JiraIssueEditorResult|nil, err: string|nil))|nil
---@return AtlasForm
local function open_editor(project_key, issue, details, on_done)
	local assignee = details and details.assignees[1]
	local reporter = details and details.reporter
	local issue_type = details and details.type

	---@type JiraIssueEditorState
	local state = {
		project_key = project_key,
		issue = issue,
		on_done = on_done,
		assignee = assignee,
		reporter = reporter,
		issue_type = issue_type,
		fields = {},
		defaults = (config.options.issues.jira.project_config[project_key] or {}).defaults or {},
		raw_description = details and details.raw_description,
		initial = {
			title = vim.trim(details and details.title or ""),
			body = details and details.description or "",
			assignee = assignee and assignee.id or false,
			reporter = reporter and reporter.id or false,
			issue_type = issue_type and issue_type.id or false,
			fields = {},
		},
		requests = requests.new(),
		loading = {},
		submitting = false,
	}

	local editor_keys = {
		{
			key = keymaps.resolve("editor.assignees"),
			desc = "assignee",
			action = function(editor)
				select_user(state, editor, "assignee")
			end,
		},
		{
			key = keymaps.resolve("editor.reporter"),
			desc = "reporter",
			action = function(editor)
				select_user(state, editor, "reporter")
			end,
		},
		{
			key = keymaps.resolve("editor.issue_type"),
			desc = "issue type",
			action = function(editor)
				select_issue_type(state, editor)
			end,
		},
		{
			key = keymaps.resolve("editor.fields"),
			desc = "fields",
			action = function(editor)
				select_field(state, editor)
			end,
		},
	}

	local preview_keys = keymaps.resolve("ui.toggle_description_mode")
	if preview_keys then
		table.insert(editor_keys, {
			key = preview_keys,
			desc = "raw preview",
			action = function(editor)
				preview_description(state, editor)
			end,
		})
	end

	local editor = form.open({
		header = issue and "Edit issue " .. issue.key or "Create issue",
		initial_title = state.initial.title,
		initial_body = state.initial.body,
		completion = {
			context = { provider = "jira", project = project_key, issue = issue and { key = issue.key } },
		},
		is_modified = function(form_editor)
			return content_modified(state, form_editor)
		end,
		meta = function()
			return render_meta(state)
		end,
		submit = function(form_editor)
			submit(state, form_editor)
		end,
		close = function(form_editor)
			close(state, form_editor)
		end,
		on_closed = function()
			state.requests.cancel()
			if not state.submitting and state.on_done then
				state.on_done(nil, nil)
			end
		end,
		keymaps = editor_keys,
	})

	if issue then
		load_edit_fields(state, editor)
	else
		load_reporter(state, editor)
	end
	if not issue and state.defaults.issue_type then
		load_default_type(state, editor)
	end
	return editor
end

---@param project_key string
---@param on_done (fun(result: JiraIssueEditorResult|nil, err: string|nil))|nil
---@return AtlasForm
function M.open(project_key, on_done)
	return open_editor(project_key, nil, nil, on_done)
end

---@param issue JiraIssue
---@param on_done (fun(result: JiraIssueEditorResult|nil, err: string|nil))|nil
---@return { cancel: fun() }|nil
function M.edit(issue, on_done)
	notify.loading("Loading " .. issue.key .. "...")
	return issues.fetch_issue(issue, { force_refresh = true }, function(details, err)
		if not details then
			err = err or "Unable to load issue"
			notify.error(err)
			if on_done then
				on_done(nil, err)
			end
			return
		end

		notify.clear()
		local project_key = issue.project and issue.project.key or issue.key:match("^(.+)-%d+$")
		open_editor(project_key, issue, details, on_done)
	end)
end

return M
