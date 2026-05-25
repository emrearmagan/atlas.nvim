local M = {}

local form = require("atlas.ui.popups.form")
local spinner = require("atlas.ui.popups.spinner")
local multi_select = require("atlas.ui.popups.multi_select")
local pulls_helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local footer = require("atlas.ui.components.footer")

---@class GitLabCreateIssueLayout
---@field container_buf integer|nil
---@field container_win integer|nil
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil

---@class GitLabCreateIssueLabel
---@field name string
---@field color string|nil

---@class GitLabCreateIssueMilestone
---@field id integer
---@field title string

---@class GitLabCreateIssuePickers
---@field list_labels fun(on_done: fun(items: GitLabCreateIssueLabel[]|nil, err: string|nil))|nil
---@field list_assignees fun(on_done: fun(items: IssueUser[]|nil, err: string|nil))|nil
---@field list_milestones fun(on_done: fun(items: GitLabCreateIssueMilestone[]|nil, err: string|nil))|nil

---@class GitLabCreateIssueFields
---@field project_path string
---@field title string
---@field body string
---@field labels GitLabCreateIssueLabel[]
---@field assignees IssueUser[]
---@field milestone GitLabCreateIssueMilestone|nil

---@class GitLabCreateIssueState
---@field fields GitLabCreateIssueFields
---@field layout GitLabCreateIssueLayout
---@field content_width integer
---@field is_submitting boolean
---@field pickers GitLabCreateIssuePickers
---@field on_done fun(result: GitLabIssueEditorResult|nil, err: string|nil)|nil

local function notify_info(msg, duration)
	footer.notify("info", tostring(msg), duration or 1200)
end

local function notify_warn(msg, duration)
	footer.notify("warn", tostring(msg), duration or 1500)
end

local function notify_error(msg)
	footer.notify("error", tostring(msg))
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param project_path string
---@return GitLabCreateIssuePickers
local function default_pickers(project_path)
	local labels_api = require("atlas.issues.providers.gitlab.api.labels")
	local users_api = require("atlas.issues.providers.gitlab.api.users")
	local milestones_api = require("atlas.issues.providers.gitlab.api.milestones")

	return {
		list_labels = function(cb)
			labels_api.list(project_path, function(items, err)
				if err or items == nil then
					cb(nil, err)
					return
				end
				local out = {}
				for _, l in ipairs(items) do
					table.insert(out, { name = l.name, color = l.color })
				end
				cb(out, nil)
			end)
		end,
		list_assignees = function(cb)
			users_api.list_members(project_path, "", cb)
		end,
		list_milestones = function(cb)
			milestones_api.list(project_path, function(items, err)
				if err or items == nil then
					cb(nil, err)
					return
				end
				local out = {}
				for _, m in ipairs(items) do
					table.insert(out, { id = m.id, title = m.title })
				end
				cb(out, nil)
			end)
		end,
	}
end

---@class GitLabIssueEditorResult
---@field url string|nil
---@field key string|nil
---@field iid integer|nil

---@param assignees IssueUser[]
---@return string
local function format_assignees(assignees)
	if type(assignees) ~= "table" or #assignees == 0 then
		return icons.general("user") .. " Unassigned"
	end

	local parts = {}
	for _, a in ipairs(assignees) do
		table.insert(parts, "@" .. tostring(a.account_id or ""))
	end

	return icons.general("user") .. " " .. table.concat(parts, ", ")
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return "AtlasTextMuted"
	end
	local name = string.format("AtlasGLLabel_%s", clean)
	local r = tonumber(clean:sub(1, 2), 16) or 0
	local g = tonumber(clean:sub(3, 4), 16) or 0
	local b = tonumber(clean:sub(5, 6), 16) or 0
	local lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	local fg = lum > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = fg, bg = "#" .. clean, bold = true })
	return name
end

---@param milestone GitLabCreateIssueMilestone|nil
---@return string
local function format_milestone(milestone)
	if type(milestone) ~= "table" then
		return "None"
	end
	return tostring(milestone.title or "")
end

---@param labels GitLabCreateIssueLabel[]
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

---@param issue_state GitLabCreateIssueState
---@return EditorPopupMetaRow[]
local function meta_rows(issue_state)
	local repo = tostring(issue_state.fields.project_path or "")
	local assignees = issue_state.fields.assignees
	local milestone = issue_state.fields.milestone

	local milestone_text = format_milestone(milestone)
	local milestone_hl = milestone and "AtlasText" or "AtlasTextMuted"
	local assignees_text = format_assignees(assignees)
	local assignees_hl = #assignees > 0 and "AtlasText" or "AtlasTextMuted"

	return {
		{
			"Project:",
			{ text = repo, hl = pulls_helper.repo_hl(repo) },
			"Milestone:",
			{ text = milestone_text, hl = milestone_hl },
		},
		{ "Assignees:", { text = assignees_text, hl = assignees_hl } },
		{ "Labels:", labels_cell(issue_state.fields.labels) },
	}
end

---@param issue_state GitLabCreateIssueState
local function get_title(issue_state)
	if not valid_buf(issue_state.layout.title_buf) then
		return ""
	end
	local lines = vim.api.nvim_buf_get_lines(issue_state.layout.title_buf, 0, -1, false)
	return vim.trim(table.concat(lines, " "))
end

---@param issue_state GitLabCreateIssueState
local function get_body(issue_state)
	if not valid_buf(issue_state.layout.desc_buf) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(issue_state.layout.desc_buf, 0, -1, false), "\n")
end

---@param issue_state GitLabCreateIssueState
local function render_meta(issue_state)
	form.render_meta(issue_state, meta_rows(issue_state))
end

---@param issue_state GitLabCreateIssueState
local function close(issue_state)
	form.close(issue_state.layout)
	issue_state.layout = {}
	issue_state.is_submitting = false
end

---@param issue_state GitLabCreateIssueState
local function confirm_close(issue_state)
	local title = get_title(issue_state)
	local body = get_body(issue_state)
	if title == "" and body == "" then
		close(issue_state)
		return
	end

	vim.ui.input({ prompt = "Discard issue draft? [y/N]: " }, function(input)
		if input ~= nil and vim.trim(tostring(input)):lower() == "y" then
			close(issue_state)
		end
	end)
end

---@param issue_state GitLabCreateIssueState
local function pick_assignees(issue_state)
	if type(issue_state.pickers.list_assignees) ~= "function" then
		notify_warn("Assignee picker not available")
		return
	end

	issue_state.pickers.list_assignees(function(items, err)
		vim.schedule(function()
			if err then
				notify_error("Load members failed: " .. tostring(err))
				return
			end
			if type(items) ~= "table" or #items == 0 then
				notify_warn("No assignable members")
				return
			end
			multi_select.open({
				items = items,
				selected = issue_state.fields.assignees,
				key = function(item)
					return tostring(item.id or item.account_id or "")
				end,
				format = function(item)
					return string.format("%s %s (@%s)", icons.general("user"), item.display_name or item.account_id, item.account_id)
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

---@param issue_state GitLabCreateIssueState
local function pick_labels(issue_state)
	if type(issue_state.pickers.list_labels) ~= "function" then
		notify_warn("Label picker not available")
		return
	end

	issue_state.pickers.list_labels(function(items, err)
		vim.schedule(function()
			if err then
				notify_error("Load labels failed: " .. tostring(err))
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
					return tostring(item.name or "")
				end,
				format = function(item)
					return tostring(item.name or "")
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

---@param issue_state GitLabCreateIssueState
local function pick_milestone(issue_state)
	if type(issue_state.pickers.list_milestones) ~= "function" then
		notify_warn("Milestone picker not available")
		return
	end

	issue_state.pickers.list_milestones(function(items, err)
		vim.schedule(function()
			if err then
				notify_error("Load milestones failed: " .. tostring(err))
				return
			end

			local choices = { "None" }
			local map = {}
			for _, item in ipairs(items or {}) do
				local label = tostring(item.title or "")
				if label ~= "" then
					table.insert(choices, label)
					map[label] = item
				end
			end

			vim.ui.select(choices, { prompt = "Select milestone:" }, function(choice)
				if choice == nil then
					return
				end
				if choice == "None" then
					issue_state.fields.milestone = nil
				else
					issue_state.fields.milestone = map[choice]
				end
				render_meta(issue_state)
			end)
		end)
	end)
end

---@param issue_state GitLabCreateIssueState
local function submit(issue_state)
	if issue_state.is_submitting then
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

	local assignee_ids = {}
	for _, a in ipairs(issue_state.fields.assignees) do
		local id = tonumber(a.id)
		if id then
			table.insert(assignee_ids, id)
		end
	end

	issue_state.is_submitting = true
	spinner.start("Creating issue…")

	local issues_api = require("atlas.issues.providers.gitlab.api.issues")
	issues_api.create_issue({
		project_path = issue_state.fields.project_path,
		title = title,
		description = get_body(issue_state),
		labels = label_names,
		assignee_ids = assignee_ids,
		milestone_id = issue_state.fields.milestone and issue_state.fields.milestone.id or nil,
	}, function(result, err)
		vim.schedule(function()
			issue_state.is_submitting = false
			spinner.stop()

			if err then
				notify_error("Create issue failed: " .. tostring(err))
				if type(issue_state.on_done) == "function" then
					issue_state.on_done(nil, err)
				end
				return
			end

			local url = result and result.url or nil
			if type(url) == "string" and url ~= "" then
				notify_info("Issue created: " .. url)
				pcall(vim.fn.setreg, "+", url)
			else
				notify_info("Issue created")
			end

			if type(issue_state.on_done) == "function" then
				issue_state.on_done({
					url = url,
					key = result and result.key or nil,
					iid = result and result.iid or nil,
				}, nil)
			end

			close(issue_state)
		end)
	end)
end

---@class GitLabIssueEditorOpts
---@field project_path string
---@field on_done fun(result: GitLabIssueEditorResult|nil, err: string|nil)|nil

---@param opts GitLabIssueEditorOpts
function M.open(opts)
	if type(opts) ~= "table" then
		notify_warn("create_issue.open: missing options")
		return
	end

	local project_path = tostring(opts.project_path or "")
	if project_path == "" then
		notify_error("create_issue.open: project_path is required")
		return
	end

	require("atlas.ui.shared.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()
	require("atlas.issues.providers.gitlab.highlights").setup()

	---@type GitLabCreateIssueState
	local issue_state = {
		fields = {
			project_path = project_path,
			title = "",
			body = "",
			labels = {},
			assignees = {},
			milestone = nil,
		},
		layout = {},
		content_width = 80,
		is_submitting = false,
		pickers = default_pickers(project_path),
		on_done = opts.on_done,
	}

	form.open(issue_state, {
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
