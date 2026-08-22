local M = {}

local form = require("atlas.ui.popups.form")
local notify = require("atlas.core.notify")
local picker = require("atlas.picker")
local pulls_helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local templates = require("atlas.issues.templates")
local request_scope = require("atlas.core.requests")
local mapper = require("atlas.issues.providers.forgejo.api.mapper")
local issues_api = require("atlas.issues.providers.forgejo.api.issues")

---@class ForgejoCreateIssueState
---@field fields { repo_slug: string, labels: table[], assignees: IssueUser[], milestone: table|nil, due_date: string|nil }
---@field issue Issue|nil
---@field layout AtlasFormLayout
---@field content_width integer
---@field is_submitting boolean
---@field closed boolean
---@field completed boolean
---@field requests AtlasRequestScope
---@field on_done fun(result: table|nil, err: string|nil)|nil

---@param hex string|nil
---@return string
local function label_hl(hex)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return "AtlasTextMuted"
	end
	local name = "AtlasForgejoIssueLabel_" .. clean
	local r = tonumber(clean:sub(1, 2), 16)
	local g = tonumber(clean:sub(3, 4), 16)
	local b = tonumber(clean:sub(5, 6), 16)
	---@cast r number
	---@cast g number
	---@cast b number
	local foreground = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = foreground, bg = "#" .. clean, bold = true })
	return name
end

---@param values table[]
---@return AtlasFormMetaCell
local function labels_cell(values)
	if #values == 0 then
		return { text = "None", hl = "AtlasTextMuted" }
	end
	local pieces, spans = {}, {}
	local cursor = 0
	for _, label in ipairs(values) do
		local name = label.name
		if name ~= "" then
			if #pieces > 0 then
				table.insert(pieces, " ")
				cursor = cursor + 1
			end
			local chip = " " .. name .. " "
			table.insert(pieces, chip)
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #chip,
				hl_group = label_hl(label.color),
			})
			cursor = cursor + #chip
		end
	end
	return { text = table.concat(pieces), spans = spans }
end

---@param state ForgejoCreateIssueState
---@return AtlasFormMetaRow[]
local function meta_rows(state)
	local assignees = {}
	for _, user in ipairs(state.fields.assignees) do
		table.insert(assignees, "@" .. user.account_id)
	end
	local assignee_text = #assignees > 0 and table.concat(assignees, ", ") or "Unassigned"
	local milestone = state.fields.milestone and state.fields.milestone.title or "None"
	local due_date = state.fields.due_date or "None"
	return {
		{
			"Repo:",
			{ text = state.fields.repo_slug, hl = pulls_helper.repo_hl(state.fields.repo_slug) },
			"Milestone:",
			{ text = milestone, hl = state.fields.milestone and "AtlasText" or "AtlasTextMuted" },
		},
		{
			"Assignees:",
			{ text = assignee_text, hl = #assignees > 0 and "AtlasText" or "AtlasTextMuted" },
			"Due:",
			{ text = due_date, hl = state.fields.due_date and "AtlasTextWarning" or "AtlasTextMuted" },
		},
		{ "Labels:", labels_cell(state.fields.labels) },
	}
end

---@param state ForgejoCreateIssueState
local function render_meta(state)
	form.render_meta(state, meta_rows(state))
end

---@param state ForgejoCreateIssueState
---@param result table|nil
---@param err string|nil
local function complete(state, result, err)
	if state.completed then
		return
	end
	state.completed = true
	if state.on_done then
		state.on_done(result, err)
	end
end

---@param state ForgejoCreateIssueState
---@param cancelled boolean|nil
local function close(state, cancelled)
	if state.closed then
		return
	end
	state.closed = true
	state.requests.cancel()
	form.close(state.layout)
	state.layout = {}
	state.is_submitting = false
	if cancelled then
		complete(state, nil, nil)
	end
end

---@param state ForgejoCreateIssueState
local function confirm_close(state)
	if state.closed then
		return
	end
	if vim.trim(form.get_title(state.layout)) == "" and vim.trim(form.get_body(state.layout)) == "" then
		close(state, true)
		return
	end
	vim.ui.input({ prompt = "Discard issue draft? [y/N]: " }, function(input)
		if not state.closed and vim.trim(tostring(input or "")):lower() == "y" then
			close(state, true)
		end
	end)
end

---@param state ForgejoCreateIssueState
local function pick_assignees(state)
	if state.closed then
		return
	end
	form.notify("loading", "Loading assignees...")
	state.requests.run(function(done)
		return issues_api.list_assignees(state.fields.repo_slug, done)
	end, function(items, err)
		if err or not items then
			form.notify("error", err or "Failed to load assignees")
			return
		end
		form.clear_notice()
		picker.multi_select({
			items = items,
			selected = state.fields.assignees,
			key = function(item)
				return item.account_id
			end,
			format_item = function(item)
				return string.format("%s %s (@%s)", icons.general("user"), item.display_name, item.account_id)
			end,
			title = "Assignees",
			on_done = function(selected)
				if state.closed then
					return
				end
				state.fields.assignees = selected
				render_meta(state)
			end,
		})
	end)
end

---@param state ForgejoCreateIssueState
local function pick_labels(state)
	if state.closed then
		return
	end
	form.notify("loading", "Loading labels...")
	state.requests.run(function(done)
		return issues_api.list_labels(state.fields.repo_slug, done)
	end, function(items, err)
		if err or not items then
			form.notify("error", err or "Failed to load labels")
			return
		end
		form.clear_notice()
		picker.multi_select({
			items = items,
			selected = state.fields.labels,
			key = function(item)
				return tostring(item.id)
			end,
			format_item = function(item)
				return item.name
			end,
			title = "Labels",
			on_done = function(selected)
				if state.closed then
					return
				end
				state.fields.labels = selected
				render_meta(state)
			end,
		})
	end)
end

---@param state ForgejoCreateIssueState
local function pick_milestone(state)
	if state.closed then
		return
	end
	form.notify("loading", "Loading milestones...")
	state.requests.run(function(done)
		return issues_api.list_milestones(state.fields.repo_slug, done)
	end, function(items, err)
		if err or not items then
			form.notify("error", err or "Failed to load milestones")
			return
		end
		form.clear_notice()
		local choices = { { id = nil, title = "None" } }
		vim.list_extend(choices, items)
		picker.select({
			title = "Milestone",
			items = choices,
			format_item = function(item)
				return item.title
			end,
			on_select = function(choice)
				if not state.closed and choice then
					state.fields.milestone = choice.id and choice or nil
					render_meta(state)
				end
			end,
		})
	end)
end

---@param state ForgejoCreateIssueState
local function pick_due_date(state)
	if state.closed then
		return
	end
	vim.ui.input({
		prompt = "Due date (YYYY-MM-DD, empty to clear): ",
		default = state.fields.due_date or "",
	}, function(value)
		if state.closed or value == nil then
			return
		end
		value = vim.trim(value)
		if value ~= "" and not value:match("^%d%d%d%d%-%d%d%-%d%d$") then
			form.notify("warn", "Due date must use YYYY-MM-DD", 1500)
			return
		end
		state.fields.due_date = value ~= "" and value or nil
		render_meta(state)
	end)
end

---@param value string|nil
---@return string|nil
local function api_due_date(value)
	return value and (value .. "T00:00:00Z") or nil
end

---@param state ForgejoCreateIssueState
---@return integer[], string[]
local function selected_values(state)
	local labels, assignees = {}, {}
	for _, label in ipairs(state.fields.labels) do
		table.insert(labels, label.id)
	end
	for _, user in ipairs(state.fields.assignees) do
		table.insert(assignees, user.account_id)
	end
	return labels, assignees
end

---@param state ForgejoCreateIssueState
---@param result table
local function finish(state, result)
	if state.closed then
		return
	end
	local editing = state.issue ~= nil
	close(state)
	complete(state, result, nil)
	notify.info(editing and "Issue updated" or "Issue created", { timeout = 1200 })
end

---@param state ForgejoCreateIssueState
local function submit(state)
	if state.closed or state.is_submitting then
		return
	end
	local title = vim.trim(form.get_title(state.layout))
	if title == "" then
		form.notify("warn", "Title is required", 1500)
		return
	end
	local labels, assignees = selected_values(state)
	local milestone = state.fields.milestone and state.fields.milestone.id or nil
	local due_date = api_due_date(state.fields.due_date)
	state.is_submitting = true
	form.notify("loading", state.issue and "Updating issue..." or "Creating issue...")

	local function failed(err)
		if state.closed then
			return
		end
		state.is_submitting = false
		form.notify("error", tostring(err or "Issue request failed"))
	end

	if not state.issue then
		state.requests.run(function(done)
			return issues_api.create({
				repo_slug = state.fields.repo_slug,
				title = title,
				body = form.get_body(state.layout),
				labels = labels,
				assignees = assignees,
				milestone = milestone,
				due_date = due_date,
			}, done)
		end, function(result, err)
			if err or not result then
				failed(err or "Invalid create issue response")
				return
			end
			finish(state, result)
		end)
		return
	end

	state.requests.run(function(done)
		return issues_api.update_issue(state.issue, {
			title = title,
			body = form.get_body(state.layout),
			assignees = assignees,
			milestone = milestone or 0,
			due_date = due_date,
			unset_due_date = due_date == nil,
		}, done)
	end, function(updated, err)
		if err or not updated then
			failed(err or "Invalid update issue response")
			return
		end
		state.requests.run(function(done)
			return issues_api.update_labels(state.issue.key, labels, done)
		end, function(ok, label_err)
			if not ok then
				failed(label_err or "Issue updated, but labels could not be updated")
				return
			end
			finish(state, {
				number = updated._raw.number,
				key = updated.key,
				url = updated.url,
				issue = updated,
			})
		end)
	end)
end

---@param raw table[]
---@return IssueUser[]
local function initial_assignees(raw)
	local result = {}
	for _, user in ipairs(raw) do
		local mapped = mapper.to_user(user)
		---@cast mapped IssueUser
		table.insert(result, mapped)
	end
	return result
end

---@param opts { repo_slug: string, issue: Issue|nil, on_done: fun(result: table|nil, err: string|nil)|nil }
function M.open(opts)
	require("atlas.ui.shared.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()
	require("atlas.issues.providers.forgejo.highlights").setup()

	local labels, assignees, milestone, due_date, initial_body = {}, {}, nil, nil, ""
	if opts.issue then
		local raw = opts.issue._raw
		labels = vim.deepcopy(raw.labels)
		assignees = initial_assignees(raw.assignees)
		milestone = vim.deepcopy(raw.milestone)
		due_date = raw.due_date and raw.due_date:match("^%d%d%d%d%-%d%d%-%d%d") or nil
		initial_body = raw.description
	end
	---@type ForgejoCreateIssueState
	local state = {
		fields = {
			repo_slug = opts.repo_slug,
			labels = labels,
			assignees = assignees,
			milestone = milestone,
			due_date = due_date,
		},
		issue = opts.issue,
		layout = {},
		content_width = 80,
		is_submitting = false,
		closed = false,
		completed = false,
		requests = request_scope.new(),
		on_done = opts.on_done,
	}

	form.open(state, {
		title_label = "Title",
		body_label = "Description",
		initial_title = opts.issue and opts.issue.summary or "",
		initial_body = initial_body,
		close = function()
			confirm_close(state)
		end,
		on_closed = function()
			close(state, true)
		end,
		submit = function()
			submit(state)
		end,
		meta = function()
			return meta_rows(state)
		end,
		keymaps = {
			{
				key = "ga",
				mode = "n",
				buffers = { "editor" },
				desc = "assignees",
				action = function()
					pick_assignees(state)
				end,
			},
			{
				key = "gl",
				mode = "n",
				buffers = { "editor" },
				desc = "labels",
				action = function()
					pick_labels(state)
				end,
			},
			{
				key = "gm",
				mode = "n",
				buffers = { "editor" },
				desc = "milestone",
				action = function()
					pick_milestone(state)
				end,
			},
			{
				key = "gd",
				mode = "n",
				buffers = { "editor" },
				desc = "due date",
				action = function()
					pick_due_date(state)
				end,
			},
			{
				key = "gT",
				mode = "n",
				buffers = { "editor" },
				desc = "templates",
				action = function()
					if state.closed then
						return
					end
					templates.open({
						get_description = function()
							return not state.closed and form.get_body(state.layout) or ""
						end,
						set_description = function(description)
							return not state.closed and form.set_body(state.layout, description) or false
						end,
						picker_kind = "atlas_forgejo_templates",
						menu_kind = "atlas_forgejo_templates_menu",
					})
				end,
			},
		},
	})

	vim.schedule(function()
		if not state.closed and vim.api.nvim_get_current_buf() == state.layout.editor_buf then
			vim.cmd("startinsert!")
		end
	end)
end

return M
