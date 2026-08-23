local M = {}

local form = require("atlas.ui.popups.form")
local notify = require("atlas.core.notify")
local picker = require("atlas.picker")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local request_scope = require("atlas.core.requests")
local users_api = require("atlas.providers.github.users").new("issues")
local templates = require("atlas.issues.templates")

---@class CreateIssueLabel
---@field name string
---@field color string|nil

---@class CreateIssueMilestone
---@field number integer
---@field title string

---@class CreateIssuePickers
---@field list_labels (fun(on_done: fun(items: CreateIssueLabel[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field list_assignees (fun(on_done: fun(items: IssueUser[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field list_milestones (fun(on_done: fun(items: CreateIssueMilestone[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil

---@class CreateIssueFields
---@field repo_slug string
---@field labels CreateIssueLabel[]
---@field assignees IssueUser[]
---@field milestone CreateIssueMilestone|nil

---@class CreateIssueState
---@field fields CreateIssueFields
---@field layout AtlasFormLayout
---@field content_width integer
---@field is_submitting boolean
---@field pickers CreateIssuePickers
---@field requests AtlasRequestScope
---@field on_done fun(result: GitHubIssueEditorResult|nil, err: string|nil)|nil

---@param repo_slug string
---@return CreateIssuePickers
local function default_pickers(repo_slug)
	local issues_api = require("atlas.issues.providers.github.api.issues")
	return {
		list_labels = function(cb)
			return issues_api.list_labels(repo_slug, cb)
		end,
		list_assignees = function(cb)
			return users_api.get_assignable_users(repo_slug, nil, cb)
		end,
		list_milestones = function(cb)
			return issues_api.list_milestones(repo_slug, cb)
		end,
	}
end

---@class GitHubIssueEditorResult
---@field url string|nil
---@field number integer|nil

---@param assignees IssueUser[]
---@return string
local function format_assignees(assignees)
	if #assignees == 0 then
		return icons.general("user") .. " Unassigned"
	end

	local parts = {}
	for _, assignee in ipairs(assignees) do
		table.insert(parts, "@" .. tostring(assignee.account_id or ""))
	end

	return icons.general("user") .. " " .. table.concat(parts, ", ")
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	if hex == nil or not hex:match("^%x%x%x%x%x%x$") then
		return "AtlasTextMuted"
	end

	local name = string.format("AtlasGHLabel_%s", hex:lower())
	vim.api.nvim_set_hl(0, name, { fg = "#000000", bg = "#" .. hex, bold = true })
	return name
end

---@param milestone CreateIssueMilestone|nil
---@return string
local function format_milestone(milestone)
	if milestone == nil then
		return "None"
	end

	return tostring(milestone.title or string.format("#%s", tostring(milestone.number or "")))
end

---@param labels CreateIssueLabel[]
---@return AtlasFormMetaCell
local function labels_cell(labels)
	if #labels == 0 then
		return { text = "None", hl = "AtlasTextMuted" }
	end

	local cursor = 0
	local pieces = {}
	local spans = {}
	for i, label in ipairs(labels) do
		local name = tostring(label.name or "")
		if name ~= "" then
			if i > 1 then
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

	local text = table.concat(pieces)
	if text == "" then
		return { text = "None", hl = "AtlasTextMuted" }
	end

	return { text = text, spans = spans }
end

---@param issue_state CreateIssueState
---@return AtlasFormMetaRow[]
local function meta_rows(issue_state)
	local repo = tostring(issue_state.fields.repo_slug or "")
	local assignees = issue_state.fields.assignees
	local milestone = issue_state.fields.milestone

	local milestone_text = format_milestone(milestone)
	local milestone_hl = milestone and "AtlasText" or "AtlasTextMuted"
	local assignees_text = format_assignees(assignees)
	local assignees_hl = #assignees > 0 and "AtlasText" or "AtlasTextMuted"

	return {
		{
			"Repo:",
			{ text = repo, hl = highlights.dynamic_for(repo:lower()) or "AtlasTextMuted" },
			"Milestone:",
			{ text = milestone_text, hl = milestone_hl },
		},
		{ "Assignees:", { text = assignees_text, hl = assignees_hl } },
		{ "Labels:", labels_cell(issue_state.fields.labels) },
	}
end

---@param issue_state CreateIssueState
local function get_title(issue_state)
	return vim.trim(form.get_title(issue_state.layout))
end

---@param issue_state CreateIssueState
local function get_body(issue_state)
	return form.get_body(issue_state.layout)
end

---@param issue_state CreateIssueState
local function render_meta(issue_state)
	form.render_meta(issue_state, meta_rows(issue_state))
end

---@param issue_state CreateIssueState
local function close(issue_state)
	issue_state.requests.cancel()
	form.close(issue_state.layout)
end

---@param issue_state CreateIssueState
local function confirm_close(issue_state)
	local title = get_title(issue_state)
	local body = get_body(issue_state)
	if title == "" and body == "" then
		close(issue_state)
		return
	end

	vim.ui.input({ prompt = "Discard issue draft? [y/N]: " }, function(input)
		if type(input) == "string" and input:match("^[yY]") then
			close(issue_state)
		end
	end)
end

---@param issue_state CreateIssueState
local function pick_assignees(issue_state)
	local list_assignees = issue_state.pickers.list_assignees
	if not list_assignees then
		form.notify("warn", "Assignee picker is not available")
		return
	end

	form.notify("loading", "Loading assignees...")
	issue_state.requests.run(list_assignees, function(items, err)
		if err then
			form.notify("error", "Failed to load assignees: " .. tostring(err))
			return
		end
		if type(items) ~= "table" or #items == 0 then
			form.notify("warn", "No assignees available")
			return
		end
		form.clear_notice()

		picker.multi_select({
			items = items,
			selected = issue_state.fields.assignees,
			key = function(item)
				return item.account_id
			end,
			format_item = function(item)
				return string.format(
					"@%s%s",
					item.account_id,
					item.display_name and item.display_name ~= item.account_id and (" — " .. item.display_name) or ""
				)
			end,
			title = "Assignees",
			on_done = function(selected)
				issue_state.fields.assignees = selected or {}
				render_meta(issue_state)
			end,
		})
	end)
end

---@param issue_state CreateIssueState
local function pick_labels(issue_state)
	local list_labels = issue_state.pickers.list_labels
	if not list_labels then
		form.notify("warn", "Label picker is not available")
		return
	end

	form.notify("loading", "Loading labels...")
	issue_state.requests.run(list_labels, function(items, err)
		if err then
			form.notify("error", "Failed to load labels: " .. tostring(err))
			return
		end
		if type(items) ~= "table" or #items == 0 then
			form.notify("warn", "No labels available")
			return
		end
		form.clear_notice()

		picker.multi_select({
			items = items,
			selected = issue_state.fields.labels,
			key = function(item)
				return item.name
			end,
			format_item = function(item)
				return tostring(item.name)
			end,
			title = "Labels",
			on_done = function(selected)
				issue_state.fields.labels = selected or {}
				render_meta(issue_state)
			end,
		})
	end)
end

---@param issue_state CreateIssueState
local function pick_milestone(issue_state)
	local list_milestones = issue_state.pickers.list_milestones
	if not list_milestones then
		form.notify("warn", "Milestone picker is not available")
		return
	end

	form.notify("loading", "Loading milestones...")
	issue_state.requests.run(list_milestones, function(items, err)
		if err then
			form.notify("error", "Failed to load milestones: " .. tostring(err))
			return
		end
		form.clear_notice()

		items = type(items) == "table" and items or {}

		local choices = { "(none)" }
		local map = {}
		for _, item in ipairs(items) do
			local label = string.format("#%s  %s", tostring(item.number), tostring(item.title))
			table.insert(choices, label)
			map[label] = item
		end

		picker.select({
			title = "Select milestone:",
			items = choices,
			on_select = function(choice)
				if choice == nil then
					return
				end
				if choice == "(none)" then
					issue_state.fields.milestone = nil
				else
					issue_state.fields.milestone = map[choice]
				end
				render_meta(issue_state)
			end,
		})
	end)
end

---@param issue_state CreateIssueState
local function submit(issue_state)
	if issue_state.is_submitting then
		return
	end

	local title = get_title(issue_state)
	if title == "" then
		form.notify("warn", "Title is required")
		return
	end

	local label_names = {}
	for _, label in ipairs(issue_state.fields.labels) do
		table.insert(label_names, label.name)
	end

	local assignee_logins = {}
	for _, assignee in ipairs(issue_state.fields.assignees) do
		table.insert(assignee_logins, assignee.account_id)
	end

	issue_state.is_submitting = true
	form.notify("loading", "Creating issue...")

	local issues_api = require("atlas.issues.providers.github.api.issues")
	issue_state.requests.run(function(done)
		return issues_api.create_issue({
			repo_slug = issue_state.fields.repo_slug,
			title = title,
			body = get_body(issue_state),
			labels = label_names,
			assignees = assignee_logins,
			milestone = issue_state.fields.milestone and issue_state.fields.milestone.title or nil,
		}, done)
	end, function(result, err)
		issue_state.is_submitting = false

		if err then
			form.notify("error", "Create issue failed: " .. tostring(err))
			if issue_state.on_done then
				issue_state.on_done(nil, err)
			end
			return
		end

		local url = result and result.url or nil
		local message = "Issue created"
		if type(url) == "string" and url ~= "" then
			message = message .. ": " .. url
			pcall(vim.fn.setreg, "+", url)
		end

		if issue_state.on_done then
			issue_state.on_done(result, nil)
		end

		close(issue_state)
		notify.info(message, { vim_notify = true })
		if type(url) == "string" and url ~= "" then
			require("atlas.commands.open").open(url)
		end
	end)
end

---@class GitHubIssueEditorOpts
---@field repo_slug string
---@field on_done fun(result: GitHubIssueEditorResult|nil, err: string|nil)|nil

---@param opts GitHubIssueEditorOpts
function M.open(opts)
	if type(opts) ~= "table" then
		notify.warn("create_issue.open: missing options", { vim_notify = true })
		return
	end

	local repo_slug = tostring(opts.repo_slug or "")
	if repo_slug == "" then
		notify.error("create_issue.open: repo_slug is required", { vim_notify = true })
		return
	end

	highlights.setup()

	---@type CreateIssueState
	local issue_state = {
		fields = {
			repo_slug = repo_slug,
			labels = {},
			assignees = {},
			milestone = nil,
		},
		layout = {},
		content_width = 80,
		is_submitting = false,
		pickers = default_pickers(repo_slug),
		requests = request_scope.new(),
		on_done = opts.on_done,
	}

	form.open(issue_state, {
		title_label = "Title",
		body_label = "Description",
		initial_title = "",
		initial_body = "",
		close = function()
			confirm_close(issue_state)
		end,
		submit = function()
			submit(issue_state)
		end,
		meta = function()
			return meta_rows(issue_state)
		end,
		keymaps = {
			{
				key = "ga",
				mode = "n",
				buffers = { "editor" },
				desc = "assignees",
				action = function()
					pick_assignees(issue_state)
				end,
			},
			{
				key = "gl",
				mode = "n",
				buffers = { "editor" },
				desc = "labels",
				action = function()
					pick_labels(issue_state)
				end,
			},
			{
				key = "gm",
				mode = "n",
				buffers = { "editor" },
				desc = "milestone",
				action = function()
					pick_milestone(issue_state)
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
							return get_body(issue_state)
						end,
						set_description = function(description)
							return form.set_body(issue_state.layout, description)
						end,
						menu_kind = "atlas_github_templates_menu",
					})
				end,
			},
		},
	})

	vim.schedule(function()
		if vim.api.nvim_get_current_buf() == issue_state.layout.editor_buf then
			vim.cmd("startinsert!")
		end
	end)
end

return M
