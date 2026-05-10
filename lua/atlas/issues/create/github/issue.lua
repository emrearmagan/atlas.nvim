local M = {}

local editor = require("atlas.ui.popups.editor")
local spinner = require("atlas.ui.popups.spinner")
local multi_select = require("atlas.ui.popups.multi_select")
local pulls_helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")

---@class CreateIssueLayout
---@field container_buf integer|nil
---@field container_win integer|nil
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil

---@class CreateIssueLabel
---@field name string
---@field color string|nil

---@class CreateIssueAssignee
---@field login string
---@field name string|nil

---@class CreateIssueMilestone
---@field number integer
---@field title string

---@class CreateIssuePickers
---@field list_labels fun(on_done: fun(items: CreateIssueLabel[]|nil, err: string|nil))|nil
---@field list_assignees fun(on_done: fun(items: CreateIssueAssignee[]|nil, err: string|nil))|nil
---@field list_milestones fun(on_done: fun(items: CreateIssueMilestone[]|nil, err: string|nil))|nil

---@class CreateIssueSubmitOpts
---@field repo_slug string
---@field title string
---@field body string
---@field labels string[]
---@field assignees string[]
---@field milestone integer|nil

---@class CreateIssueFields
---@field repo_slug string
---@field title string
---@field body string
---@field labels CreateIssueLabel[]
---@field assignees CreateIssueAssignee[]
---@field milestone CreateIssueMilestone|nil

---@class CreateIssueState
---@field fields CreateIssueFields
---@field layout CreateIssueLayout
---@field content_width integer
---@field is_submitting boolean
---@field pickers CreateIssuePickers
---@field on_submit fun(opts: CreateIssueSubmitOpts, on_done: fun(result: { url: string|nil, number: integer|nil }|nil, err: string|nil))|nil

local function notify(level, msg)
	vim.notify("[Atlas] " .. tostring(msg), level)
end

local function notify_info(msg)
	notify(vim.log.levels.INFO, msg)
end

local function notify_warn(msg)
	notify(vim.log.levels.WARN, msg)
end

local function notify_error(msg)
	notify(vim.log.levels.ERROR, msg)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param assignees CreateIssueAssignee[]
---@return string
local function format_assignees(assignees)
	if type(assignees) ~= "table" or #assignees == 0 then
		return icons.general("user") .. " Unassigned"
	end

	local parts = {}
	for _, assignee in ipairs(assignees) do
		table.insert(parts, "@" .. tostring(assignee.login or ""))
	end

	return icons.general("user") .. " " .. table.concat(parts, ", ")
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	if type(hex) ~= "string" or not hex:match("^%x%x%x%x%x%x$") then
		return "AtlasTextMuted"
	end

	local name = string.format("AtlasGHLabel_%s", hex:lower())
	vim.api.nvim_set_hl(0, name, { bg = "#" .. hex, bold = true })
	return name
end

---@param milestone CreateIssueMilestone|nil
---@return string
local function format_milestone(milestone)
	if type(milestone) ~= "table" then
		return "None"
	end

	return tostring(milestone.title or string.format("#%s", tostring(milestone.number or "")))
end

---@param labels CreateIssueLabel[]
---@return EditorPopupMetaCell
local function labels_cell(labels)
	if type(labels) ~= "table" or #labels == 0 then
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
---@return EditorPopupMetaRow[]
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
			{ text = repo, hl = pulls_helper.repo_hl(repo) },
			"Milestone:",
			{ text = milestone_text, hl = milestone_hl },
		},
		{ "Assignees:", { text = assignees_text, hl = assignees_hl } },
		{ "Labels:", labels_cell(issue_state.fields.labels) },
	}
end

---@param issue_state CreateIssueState
local function get_title(issue_state)
	if not valid_buf(issue_state.layout.title_buf) then
		return ""
	end

	local lines = vim.api.nvim_buf_get_lines(issue_state.layout.title_buf, 0, -1, false)
	return vim.trim(table.concat(lines, " "))
end

---@param issue_state CreateIssueState
local function get_body(issue_state)
	if not valid_buf(issue_state.layout.desc_buf) then
		return ""
	end

	return table.concat(vim.api.nvim_buf_get_lines(issue_state.layout.desc_buf, 0, -1, false), "\n")
end

---@param issue_state CreateIssueState
local function render_meta(issue_state)
	editor.render_meta(issue_state, meta_rows(issue_state))
end

---@param issue_state CreateIssueState
local function close(issue_state)
	spinner.stop()
	editor.close(issue_state.layout)
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
	if type(issue_state.pickers.list_assignees) ~= "function" then
		notify_warn("Assignee picker is not available")
		return
	end

	spinner.start("Loading assignees…")
	issue_state.pickers.list_assignees(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then
				notify_error("Failed to load assignees: " .. tostring(err))
				return
			end
			if type(items) ~= "table" or #items == 0 then
				notify_warn("No assignees available")
				return
			end

			multi_select.open({
				items = items,
				selected = issue_state.fields.assignees,
				key = function(item)
					return item.login
				end,
				format = function(item)
					return string.format("@%s%s", item.login, item.name and (" — " .. item.name) or "")
				end,
				prompt = "Toggle assignees:",
				on_done = function(selected)
					issue_state.fields.assignees = selected or {}
					render_meta(issue_state)
				end,
			})
		end)
	end)
end

---@param issue_state CreateIssueState
local function pick_labels(issue_state)
	if type(issue_state.pickers.list_labels) ~= "function" then
		notify_warn("Label picker is not available")
		return
	end

	spinner.start("Loading labels…")
	issue_state.pickers.list_labels(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then
				notify_error("Failed to load labels: " .. tostring(err))
				return
			end
			if type(items) ~= "table" or #items == 0 then
				notify_warn("No labels available")
				return
			end

			multi_select.open({
				items = items,
				selected = issue_state.fields.labels,
				key = function(item)
					return item.name
				end,
				format = function(item)
					return tostring(item.name)
				end,
				prompt = "Toggle labels:",
				on_done = function(selected)
					issue_state.fields.labels = selected or {}
					render_meta(issue_state)
				end,
			})
		end)
	end)
end

---@param issue_state CreateIssueState
local function pick_milestone(issue_state)
	if type(issue_state.pickers.list_milestones) ~= "function" then
		notify_warn("Milestone picker is not available")
		return
	end

	spinner.start("Loading milestones…")
	issue_state.pickers.list_milestones(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then
				notify_error("Failed to load milestones: " .. tostring(err))
				return
			end

			items = type(items) == "table" and items or {}

			local choices = { "(none)" }
			local map = {}
			for _, item in ipairs(items) do
				local label = string.format("#%s · %s", tostring(item.number), tostring(item.title))
				table.insert(choices, label)
				map[label] = item
			end

			vim.ui.select(choices, { prompt = "Select milestone:" }, function(choice)
				if choice == nil then
					return
				end
				if choice == "(none)" then
					issue_state.fields.milestone = nil
				else
					issue_state.fields.milestone = map[choice]
				end
				render_meta(issue_state)
			end)
		end)
	end)
end

---@param issue_state CreateIssueState
local function submit(issue_state)
	if issue_state.is_submitting then
		return
	end

	if type(issue_state.on_submit) ~= "function" then
		notify_error("Submit handler not configured")
		return
	end

	local title = get_title(issue_state)
	if title == "" then
		notify_warn("Title is required")
		return
	end

	local label_names = {}
	for _, label in ipairs(issue_state.fields.labels) do
		table.insert(label_names, label.name)
	end

	local assignee_logins = {}
	for _, assignee in ipairs(issue_state.fields.assignees) do
		table.insert(assignee_logins, assignee.login)
	end

	issue_state.is_submitting = true
	spinner.start("Creating issue…")

	issue_state.on_submit({
		repo_slug = issue_state.fields.repo_slug,
		title = title,
		body = get_body(issue_state),
		labels = label_names,
		assignees = assignee_logins,
		milestone = issue_state.fields.milestone and issue_state.fields.milestone.number or nil,
	}, function(result, err)
		vim.schedule(function()
			issue_state.is_submitting = false
			spinner.stop()

			if err then
				notify_error("Create issue failed: " .. tostring(err))
				return
			end

			local url = result and result.url or nil
			if type(url) == "string" and url ~= "" then
				notify_info("Issue created: " .. url)
				pcall(vim.fn.setreg, "+", url)
			else
				notify_info("Issue created")
			end

			close(issue_state)
		end)
	end)
end

---@class CreateIssueOpenOpts
---@field repo_slug string
---@field initial_title string|nil
---@field initial_body string|nil
---@field initial_labels CreateIssueLabel[]|nil
---@field initial_assignees CreateIssueAssignee[]|nil
---@field initial_milestone CreateIssueMilestone|nil
---@field pickers CreateIssuePickers
---@field on_submit fun(opts: CreateIssueSubmitOpts, on_done: fun(result: { url: string|nil, number: integer|nil }|nil, err: string|nil))

---@param opts CreateIssueOpenOpts
function M.open(opts)
	if type(opts) ~= "table" then
		notify_warn("create_issue.open: missing options")
		return
	end

	if type(opts.on_submit) ~= "function" then
		notify_error("create_issue.open: on_submit is required")
		return
	end

	require("atlas.ui.shared.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()

	---@type CreateIssueState
	local issue_state = {
		fields = {
			repo_slug = opts.repo_slug,
			title = opts.initial_title or "",
			body = opts.initial_body or "",
			labels = type(opts.initial_labels) == "table" and opts.initial_labels or {},
			assignees = type(opts.initial_assignees) == "table" and opts.initial_assignees or {},
			milestone = opts.initial_milestone,
		},
		layout = {},
		content_width = 80,
		is_submitting = false,
		pickers = type(opts.pickers) == "table" and opts.pickers or {},
		on_submit = opts.on_submit,
	}

	editor.open(issue_state, {
		title = " Create Issue ",
		min_height = 22,
		meta_height = 3,
		title_winbar = "Title",
		desc_winbar = "Description",
		initial_title = issue_state.fields.title,
		initial_body = issue_state.fields.body,
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
				buffers = { "title", "desc" },
				desc = "assignees",
				show_in_footer = true,
				action = function()
					pick_assignees(issue_state)
				end,
			},
			{
				key = "gl",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "labels",
				show_in_footer = true,
				action = function()
					pick_labels(issue_state)
				end,
			},
			{
				key = "gm",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "milestone",
				show_in_footer = true,
				action = function()
					pick_milestone(issue_state)
				end,
			},
		},
	})

	vim.schedule(function()
		if vim.api.nvim_get_current_buf() == issue_state.layout.title_buf then
			vim.cmd("startinsert!")
		end
	end)
end

return M
