local M = {}

local form = require("atlas.ui.form")
local icons = require("atlas.ui.shared.icons")
local mapper = require("atlas.issues.providers.shortcut.api.mapper")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local requests = require("atlas.core.requests")
local stories = require("atlas.issues.providers.shortcut.api.stories")
local users = require("atlas.providers.shortcut.users")
local workflows = require("atlas.issues.providers.shortcut.api.workflows")

---@class ShortcutStoryEditorValues
---@field name string
---@field description string
---@field story_type ShortcutStoryType
---@field workflow_state_id integer|nil
---@field owner_ids string[]

---@class ShortcutStoryEditorState
---@field issue ShortcutIssue|nil
---@field on_done (fun(result: { key: string, url?: string }|nil, err: string|nil))|nil
---@field story_type ShortcutStoryType
---@field workflow_state_id integer|nil
---@field workflow_state_name string|nil
---@field owners ShortcutUser[]
---@field initial ShortcutStoryEditorValues
---@field loading table<string, boolean>
---@field requests AtlasRequestScope
---@field submitting boolean

---@param owners ShortcutUser[]
---@return string[]
local function owner_ids(owners)
	local ids = {}
	for _, owner in ipairs(owners) do
		ids[#ids + 1] = owner.id
	end
	table.sort(ids)
	return ids
end

---@param state ShortcutStoryEditorState
---@param editor AtlasForm
---@return ShortcutStoryEditorValues
local function values(state, editor)
	local content = form.get_content(editor)
	return {
		name = vim.trim(content.title),
		description = content.body,
		story_type = state.story_type,
		workflow_state_id = state.workflow_state_id,
		owner_ids = owner_ids(state.owners),
	}
end

---@param state ShortcutStoryEditorState
---@param editor AtlasForm
---@return boolean
local function is_modified(state, editor)
	return not vim.deep_equal(values(state, editor), state.initial)
end

---@param state ShortcutStoryEditorState
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

---@param state ShortcutStoryEditorState
---@param editor AtlasForm
local function pick_story_type(state, editor)
	if state.submitting then
		return
	end
	picker.select({
		title = "Story type",
		items = { "feature", "bug", "chore" },
		format_item = function(story_type)
			return mapper.to_issue_type(story_type).icon.icon .. " " .. story_type
		end,
		on_select = function(story_type)
			if story_type and not editor.closed and not state.submitting then
				state.story_type = story_type
				form.render_meta(editor)
			end
		end,
	})
end

---@param state ShortcutStoryEditorState
---@param editor AtlasForm
local function pick_workflow_state(state, editor)
	if state.submitting or state.loading.states then
		return
	end
	state.loading.states = true
	editor.statusline:notify("loading", "Loading workflow states...")
	form.render_meta(editor)
	state.requests.run(workflows.list_states, function(states, err)
		state.loading.states = nil
		render_loading(state, editor)
		if state.submitting then
			return
		elseif err or states == nil then
			editor.statusline:notify("error", err or "Failed to load workflow states")
			return
		end
		table.sort(states, function(a, b)
			if a.workflow_name == b.workflow_name then
				return a.position < b.position
			end
			return a.workflow_name < b.workflow_name
		end)
		picker.select({
			title = "Workflow state",
			items = states,
			format_item = function(workflow_state)
				return string.format("%s — %s", workflow_state.workflow_name, workflow_state.name)
			end,
			on_select = function(workflow_state)
				if workflow_state and not editor.closed and not state.submitting then
					state.workflow_state_id = workflow_state.id
					state.workflow_state_name = workflow_state.name
					form.render_meta(editor)
				end
			end,
		})
	end)
end

---@param state ShortcutStoryEditorState
---@param editor AtlasForm
local function pick_owners(state, editor)
	if state.submitting or state.loading.owners then
		return
	end
	state.loading.owners = true
	editor.statusline:notify("loading", "Loading Shortcut members...")
	form.render_meta(editor)
	state.requests.run(users.list, function(items, err)
		state.loading.owners = nil
		render_loading(state, editor)
		if state.submitting then
			return
		elseif err or items == nil then
			editor.statusline:notify("error", err or "Failed to load members")
			return
		end
		local selected, available = {}, {}
		for _, owner in ipairs(state.owners) do
			selected[owner.id] = true
		end
		for _, user in ipairs(items) do
			if not user.disabled or selected[user.id] then
				table.insert(available, user)
			end
		end
		picker.multi_select({
			title = "Owners",
			items = available,
			selected = state.owners,
			key = function(user)
				return user.id
			end,
			format_item = function(user)
				return icons.get("user") .. " " .. user.name
			end,
			on_done = function(owners)
				if not editor.closed and not state.submitting then
					state.owners = owners
					form.render_meta(editor)
				end
			end,
		})
	end)
end

---@param state ShortcutStoryEditorState
---@return AtlasFormMetaRow[]
local function render_meta(state)
	local type_style = mapper.to_issue_type(state.story_type).icon
	local names = {}
	for _, owner in ipairs(state.owners) do
		names[#names + 1] = owner.name
	end
	return {
		{
			{ key = "Type:", value = type_style.icon .. " " .. state.story_type, hl = type_style.hl_group },
			{
				key = "State:",
				value = state.workflow_state_name or (state.workflow_state_id and "Current" or "Required"),
				hl = state.workflow_state_id and "Normal" or "AtlasTextMuted",
				loading = state.loading.states,
			},
		},
		{
			{
				key = "Owners:",
				value = icons.get("user") .. " " .. (#names > 0 and table.concat(names, ", ") or "Unassigned"),
				hl = #names > 0 and "Normal" or "AtlasTextMuted",
				loading = state.loading.owners,
			},
		},
	}
end

---@param state ShortcutStoryEditorState
---@param editor AtlasForm
local function submit(state, editor)
	if state.submitting then
		return
	end
	local current = values(state, editor)
	if current.name == "" then
		notify.warn("Name is required")
		return
	elseif not current.workflow_state_id then
		notify.warn("Workflow state is required")
		return
	elseif state.issue and not is_modified(state, editor) then
		form.close(editor)
		notify.info("No changes")
		return
	end

	state.submitting = true
	vim.bo[editor.editor_buf].modifiable = false
	editor.statusline:notify("loading", state.issue and "Saving Story..." or "Creating Story...")
	local function done(result, err)
		editor.statusline:clear_notice()
		if not result then
			err = err or "Story save failed"
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
		notify.info((state.issue and "Updated #" or "Created #") .. result.key, { vim_notify = true })
		if not state.issue and result.url then
			pcall(vim.fn.setreg, "+", result.url)
			if not was_closed then
				require("atlas.commands.open").open(result.url)
			end
		end
	end

	if state.issue then
		local fields = {}
		for key, value in pairs(current) do
			if not vim.deep_equal(value, state.initial[key]) then
				fields[key] = value
			end
		end
		return stories.update(state.issue, fields, function(ok, err)
			done(ok and { key = state.issue.key } or nil, err)
		end)
	end
	return stories.create(current, done)
end

---@param state ShortcutStoryEditorState
---@param editor AtlasForm
local function close(state, editor)
	if state.submitting then
		return
	elseif not is_modified(state, editor) then
		form.close(editor)
	else
		vim.ui.input({ prompt = "Discard Story changes? [y/N]: " }, function(answer)
			if not state.submitting and vim.trim(answer or ""):lower() == "y" then
				form.close(editor)
			end
		end)
	end
end

---@param issue ShortcutIssue|nil
---@param details ShortcutIssueDetails|nil
---@param on_done (fun(result: { key: string, url?: string }|nil, err: string|nil))|nil
---@return AtlasForm
local function open_editor(issue, details, on_done)
	---@type ShortcutStoryEditorState
	local state = {
		issue = issue,
		on_done = on_done,
		story_type = details and details.story_type or "feature",
		workflow_state_id = details and details.workflow_state_id,
		workflow_state_name = issue
				and details
				and issue.workflow_state_id == details.workflow_state_id
				and issue.status
			or nil,
		owners = details and details.assignees or {},
		initial = {},
		loading = {},
		requests = requests.new(),
		submitting = false,
	}
	state.initial = {
		name = vim.trim(details and details.title or ""),
		description = details and details.description or "",
		story_type = state.story_type,
		workflow_state_id = state.workflow_state_id,
		owner_ids = owner_ids(state.owners),
	}
	return form.open({
		header = issue and "Edit Story #" .. issue.key or "Create Story",
		initial_title = state.initial.name,
		initial_body = state.initial.description,
		completion = { context = { provider = "shortcut", issue = issue and { key = issue.key } } },
		is_modified = issue and function(editor)
			return is_modified(state, editor)
		end,
		meta = function()
			return render_meta(state)
		end,
		submit = function(editor)
			submit(state, editor)
		end,
		close = function(editor)
			close(state, editor)
		end,
		on_closed = function()
			state.requests.cancel()
			if not state.submitting and state.on_done then
				state.on_done(nil, nil)
			end
		end,
		keymaps = {
			{
				key = "gt",
				desc = "Story type",
				action = function(editor)
					pick_story_type(state, editor)
				end,
			},
			{
				key = "gw",
				desc = "workflow state",
				action = function(editor)
					pick_workflow_state(state, editor)
				end,
			},
			{
				key = "ga",
				desc = "owners",
				action = function(editor)
					pick_owners(state, editor)
				end,
			},
		},
	})
end

---@param on_done (fun(result: { key: string, url?: string }|nil, err: string|nil))|nil
---@return AtlasForm
function M.open(on_done)
	return open_editor(nil, nil, on_done)
end

---@param issue ShortcutIssue
---@param on_done (fun(result: { key: string, url?: string }|nil, err: string|nil))|nil
---@return { cancel: fun() }|nil
function M.edit(issue, on_done)
	notify.loading("Loading #" .. issue.key .. "...")
	return stories.get(issue.id, { force_refresh = true }, function(details, err)
		if not details then
			err = err or "Failed to load Story"
			notify.error(err)
			if on_done then
				on_done(nil, err)
			end
			return
		end
		notify.clear()
		open_editor(issue, details, on_done)
	end)
end

return M
