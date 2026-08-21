local M = {}

local form = require("atlas.ui.popups.form")
local icons = require("atlas.ui.shared.icons")
local members_api = require("atlas.issues.providers.shortcut.api.members")
local picker = require("atlas.ui.picker")
local requests = require("atlas.core.requests")
local templates = require("atlas.issues.templates")
local workflows_api = require("atlas.issues.providers.shortcut.api.workflows")

---@class ShortcutStoryEditorFields
---@field name string
---@field description string
---@field story_type ShortcutStoryType
---@field workflow_state_id integer|nil
---@field workflow_state_name string|nil
---@field owners ShortcutIssueUser[]

---@class ShortcutStoryEditorState
---@field fields ShortcutStoryEditorFields
---@field initial ShortcutStoryEditorFields
---@field layout AtlasFormLayout
---@field content_width integer
---@field is_submitting boolean
---@field requests AtlasRequestScope
---@field on_submit fun(fields: ShortcutStoryEditorFields, done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field on_cancel fun()|nil

---@type string[]
local STORY_TYPES = { "feature", "bug", "chore" }

---@param users ShortcutIssueUser[]
---@return string
local function owner_signature(users)
	local ids = {}
	for _, user in ipairs(users) do
		table.insert(ids, user.account_id)
	end
	table.sort(ids)
	return table.concat(ids, "\n")
end

---@param state ShortcutStoryEditorState
---@return string
local function name(state)
	return vim.trim(form.get_title(state.layout))
end

---@param state ShortcutStoryEditorState
---@return string
local function description(state)
	return form.get_body(state.layout)
end

---@param state ShortcutStoryEditorState
---@return boolean
local function is_modified(state)
	return name(state) ~= state.initial.name
		or description(state) ~= state.initial.description
		or state.fields.story_type ~= state.initial.story_type
		or state.fields.workflow_state_id ~= state.initial.workflow_state_id
		or owner_signature(state.fields.owners) ~= owner_signature(state.initial.owners)
end

---@param state ShortcutStoryEditorState
---@param cancelled boolean
local function close(state, cancelled)
	state.requests.cancel()
	form.close(state.layout)
	if cancelled and state.on_cancel then
		state.on_cancel()
		state.on_cancel = nil
	end
end

---@param state ShortcutStoryEditorState
local function confirm_close(state)
	if not is_modified(state) then
		close(state, true)
		return
	end

	vim.ui.input({ prompt = "Discard Story changes? [y/N]: " }, function(input)
		if vim.trim(input or ""):lower() == "y" then
			close(state, true)
		end
	end)
end

---@param owners ShortcutIssueUser[]
---@return AtlasFormMetaCell
local function owners_cell(owners)
	if #owners == 0 then
		return { text = icons.general("user") .. " Unassigned", hl = "AtlasTextMuted" }
	end

	local names = {}
	for _, owner in ipairs(owners) do
		table.insert(names, owner.display_name)
	end
	return { text = icons.general("user") .. " " .. table.concat(names, ", "), hl = "AtlasText" }
end

---@param state ShortcutStoryEditorState
---@return AtlasFormMetaRow[]
local function meta_rows(state)
	local type_icon, type_hl = icons.issues_type(state.fields.story_type, "shortcut")
	local state_name = state.fields.workflow_state_name or (state.fields.workflow_state_id and "Current" or "Required")
	return {
		{
			"Type:",
			{ text = string.format("%s %s", type_icon, state.fields.story_type), hl = type_hl },
			"State:",
			{ text = state_name, hl = state.fields.workflow_state_id and "AtlasText" or "AtlasTextMuted" },
		},
		{ "Owners:", owners_cell(state.fields.owners) },
	}
end

---@param state ShortcutStoryEditorState
local function render_meta(state)
	form.render_meta(state, meta_rows(state))
end

---@param state ShortcutStoryEditorState
local function pick_story_type(state)
	picker.find({
		title = "Story type",
		items = STORY_TYPES,
		key = function(story_type)
			return story_type
		end,
		format_item = function(story_type)
			local icon = icons.issues_type(story_type, "shortcut")
			return string.format("%s %s", icon, story_type)
		end,
		on_select = function(story_type)
			if story_type then
				---@cast story_type ShortcutStoryType
				state.fields.story_type = story_type
				render_meta(state)
			end
		end,
	})
end

---@param state ShortcutStoryEditorState
local function pick_workflow_state(state)
	form.notify("loading", "Loading workflow states...")
	state.requests.run(function(done)
		return workflows_api.list_states(done)
	end, function(states, err)
		if err or states == nil then
			form.notify("error", err or "Failed to load workflow states")
			return
		end

		table.sort(states, function(a, b)
			if a.workflow_name == b.workflow_name then
				return a.position < b.position
			end
			return a.workflow_name < b.workflow_name
		end)
		form.clear_notice()

		picker.find({
			title = "Workflow state",
			items = states,
			key = function(workflow_state)
				return tostring(workflow_state.id)
			end,
			format_item = function(workflow_state)
				return string.format("%s — %s", workflow_state.workflow_name, workflow_state.name)
			end,
			on_select = function(workflow_state)
				if workflow_state then
					state.fields.workflow_state_id = workflow_state.id
					state.fields.workflow_state_name = workflow_state.name
					render_meta(state)
				end
			end,
		})
	end)
end

---@param state ShortcutStoryEditorState
local function pick_owners(state)
	form.notify("loading", "Loading Shortcut members...")
	state.requests.run(function(done)
		return members_api.list(done)
	end, function(users, err)
		if err or users == nil then
			form.notify("error", err or "Failed to load members")
			return
		end
		---@cast users ShortcutIssueUser[]

		local selected = {}
		for _, owner in ipairs(state.fields.owners) do
			selected[owner.account_id] = true
		end
		local available = {}
		for _, user in ipairs(users) do
			if not user.disabled or selected[user.account_id] then
				table.insert(available, user)
			end
		end
		form.clear_notice()

		picker.multi_select({
			title = "Owners",
			items = available,
			selected = state.fields.owners,
			key = function(user)
				return user.account_id
			end,
			format_item = function(user)
				return string.format("%s %s", icons.general("user"), user.display_name)
			end,
			on_done = function(owners)
				state.fields.owners = owners
				render_meta(state)
			end,
		})
	end)
end

---@param state ShortcutStoryEditorState
local function submit(state)
	if state.is_submitting then
		return
	end

	local story_name = name(state)
	if story_name == "" then
		form.notify("warn", "Name is required")
		return
	end
	if state.fields.workflow_state_id == nil then
		form.notify("warn", "Workflow state is required")
		return
	end

	local fields = vim.deepcopy(state.fields)
	fields.name = story_name
	fields.description = description(state)
	state.is_submitting = true
	form.notify("loading", state.initial.name == "" and "Creating Story..." or "Saving Story...")
	state.requests.run(function(done)
		return state.on_submit(fields, done)
	end, function(ok, err)
		vim.schedule(function()
			state.is_submitting = false
			if ok then
				close(state, false)
				return
			end
			form.notify("error", err or "Story save failed")
		end)
	end)
end

---@param on_submit fun(fields: ShortcutStoryEditorFields, done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@param initial ShortcutStoryEditorFields
---@param on_cancel? fun()
function M.open(on_submit, initial, on_cancel)
	---@type ShortcutStoryEditorState
	local state = {
		fields = vim.deepcopy(initial),
		initial = vim.deepcopy(initial),
		layout = {},
		content_width = 80,
		is_submitting = false,
		requests = requests.new(),
		on_submit = on_submit,
		on_cancel = on_cancel,
	}

	form.open(state, {
		title_label = "Name",
		body_label = "Description",
		initial_title = initial.name,
		initial_body = initial.description,
		close = function()
			confirm_close(state)
		end,
		submit = function()
			submit(state)
		end,
		meta = function()
			return meta_rows(state)
		end,
		keymaps = {
			{
				key = "gt",
				mode = "n",
				buffers = { "editor" },
				desc = "Story type",
				action = function()
					pick_story_type(state)
				end,
			},
			{
				key = "gw",
				mode = "n",
				buffers = { "editor" },
				desc = "workflow state",
				action = function()
					pick_workflow_state(state)
				end,
			},
			{
				key = "ga",
				mode = "n",
				buffers = { "editor" },
				desc = "owners",
				action = function()
					pick_owners(state)
				end,
			},
			{
				key = "gT",
				mode = "n",
				buffers = { "editor" },
				desc = "templates",
				action = function()
					templates.open({
						get_description = function()
							return description(state)
						end,
						set_description = function(value)
							return form.set_body(state.layout, value)
						end,
						menu_kind = "atlas_shortcut_templates_menu",
					})
				end,
			},
		},
	})

	vim.schedule(function()
		if vim.api.nvim_get_current_buf() == state.layout.editor_buf then
			vim.cmd("startinsert!")
		end
	end)
end

return M
