local M = {}

local form = require("atlas.ui.popups.form")
local spinner = require("atlas.ui.popups.spinner")
local multi_select = require("atlas.ui.popups.multi_select")
local pulls_helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local template_store = require("atlas.issues.templates")

---@class GiteaCreateIssueLabel
---@field id integer
---@field name string
---@field color string|nil

---@class GiteaCreateIssueMilestone
---@field id integer
---@field title string

---@class GiteaCreateIssuePickers
---@field list_labels fun(on_done: fun(items: GiteaCreateIssueLabel[]|nil, err: string|nil))|nil
---@field list_assignees fun(on_done: fun(items: IssueUser[]|nil, err: string|nil))|nil
---@field list_milestones fun(on_done: fun(items: GiteaCreateIssueMilestone[]|nil, err: string|nil))|nil

---@class GiteaCreateIssueFields
---@field repo_slug string
---@field title string
---@field body string
---@field labels GiteaCreateIssueLabel[]
---@field assignees IssueUser[]
---@field milestone GiteaCreateIssueMilestone|nil

---@class GiteaCreateIssueLayout
---@field container_buf integer|nil
---@field container_win integer|nil
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil

---@class GiteaCreateIssueState
---@field fields GiteaCreateIssueFields
---@field layout GiteaCreateIssueLayout
---@field content_width integer
---@field is_submitting boolean
---@field pickers GiteaCreateIssuePickers
---@field on_done fun(result: table|nil, err: string|nil)|nil

local function notify(level, msg)
	vim.notify("[Atlas] " .. tostring(msg), level)
end
local function notify_info(msg) notify(vim.log.levels.INFO, msg) end
local function notify_warn(msg) notify(vim.log.levels.WARN, msg) end
local function notify_error(msg) notify(vim.log.levels.ERROR, msg) end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param repo_slug string
---@return GiteaCreateIssuePickers
local function default_pickers(repo_slug)
	local issues_api = require("atlas.issues.providers.gitea.api.issues")
	local users_api = require("atlas.issues.providers.gitea.api.users")
	return {
		list_labels = function(cb)
			issues_api.list_labels(repo_slug, cb)
		end,
		list_assignees = function(cb)
			users_api.get_assignable_users(repo_slug, nil, cb)
		end,
		list_milestones = function(cb)
			issues_api.list_milestones(repo_slug, cb)
		end,
	}
end

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
	if #clean ~= 6 then return "AtlasTextMuted" end
	local name = "AtlasGiteaLabel_" .. clean
	local r = tonumber(clean:sub(1, 2), 16) or 0
	local g = tonumber(clean:sub(3, 4), 16) or 0
	local b = tonumber(clean:sub(5, 6), 16) or 0
	local lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	local fg = lum > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = fg, bg = "#" .. clean, bold = true })
	return name
end

---@param milestone GiteaCreateIssueMilestone|nil
---@return string
local function format_milestone(milestone)
	if type(milestone) ~= "table" then return "None" end
	return tostring(milestone.title or string.format("#%s", tostring(milestone.id or "")))
end

---@param labels GiteaCreateIssueLabel[]
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
			table.insert(spans, { start_col = cursor, end_col = cursor + #chip, hl_group = label_hl(label.color) })
			cursor = cursor + #chip
		end
	end
	local text = table.concat(pieces)
	if text == "" then return { text = "None", hl = "AtlasTextMuted" } end
	return { text = text, spans = spans }
end

---@param issue_state GiteaCreateIssueState
---@return EditorPopupMetaRow[]
local function meta_rows(issue_state)
	local repo = tostring(issue_state.fields.repo_slug or "")
	local assignees = issue_state.fields.assignees
	local milestone = issue_state.fields.milestone
	return {
		{
			"Repo:",
			{ text = repo, hl = pulls_helper.repo_hl(repo) },
			"Milestone:",
			{ text = format_milestone(milestone), hl = milestone and "AtlasText" or "AtlasTextMuted" },
		},
		{ "Assignees:", { text = format_assignees(assignees), hl = #assignees > 0 and "AtlasText" or "AtlasTextMuted" } },
		{ "Labels:", labels_cell(issue_state.fields.labels) },
	}
end

---@param issue_state GiteaCreateIssueState
local function get_title(issue_state)
	if not valid_buf(issue_state.layout.title_buf) then return "" end
	local lines = vim.api.nvim_buf_get_lines(issue_state.layout.title_buf, 0, -1, false)
	return vim.trim(table.concat(lines, " "))
end

---@param issue_state GiteaCreateIssueState
local function get_body(issue_state)
	if not valid_buf(issue_state.layout.desc_buf) then return "" end
	return table.concat(vim.api.nvim_buf_get_lines(issue_state.layout.desc_buf, 0, -1, false), "\n")
end

---@param issue_state GiteaCreateIssueState
local function render_meta(issue_state)
	form.render_meta(issue_state, meta_rows(issue_state))
end

---@param issue_state GiteaCreateIssueState
local function close(issue_state)
	spinner.stop()
	form.close(issue_state.layout)
end

---@param issue_state GiteaCreateIssueState
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

---@param issue_state GiteaCreateIssueState
local function pick_assignees(issue_state)
	if type(issue_state.pickers.list_assignees) ~= "function" then
		notify_warn("Assignee picker is not available")
		return
	end
	spinner.start("Loading assignees…")
	issue_state.pickers.list_assignees(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then notify_error("Failed to load assignees: " .. tostring(err)) return end
			if type(items) ~= "table" or #items == 0 then notify_warn("No assignees available") return end
			multi_select.open({
				items = items,
				selected = issue_state.fields.assignees,
				key = function(item) return item.account_id end,
				format = function(item)
					return string.format("@%s%s", item.account_id,
						item.display_name and item.display_name ~= item.account_id
						and (" — " .. item.display_name) or "")
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

---@param issue_state GiteaCreateIssueState
local function pick_labels(issue_state)
	if type(issue_state.pickers.list_labels) ~= "function" then
		notify_warn("Label picker is not available")
		return
	end
	spinner.start("Loading labels…")
	issue_state.pickers.list_labels(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then notify_error("Failed to load labels: " .. tostring(err)) return end
			if type(items) ~= "table" or #items == 0 then notify_warn("No labels available") return end
			multi_select.open({
				items = items,
				selected = issue_state.fields.labels,
				key = function(item) return tostring(item.id or item.name) end,
				format = function(item) return tostring(item.name) end,
				prompt = "Toggle labels:",
				on_done = function(selected)
					issue_state.fields.labels = selected or {}
					render_meta(issue_state)
				end,
			})
		end)
	end)
end

---@param issue_state GiteaCreateIssueState
local function pick_milestone(issue_state)
	if type(issue_state.pickers.list_milestones) ~= "function" then
		notify_warn("Milestone picker is not available")
		return
	end
	spinner.start("Loading milestones…")
	issue_state.pickers.list_milestones(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then notify_error("Failed to load milestones: " .. tostring(err)) return end
			items = type(items) == "table" and items or {}
			local choices = { "(none)" }
			local map = {}
			for _, item in ipairs(items) do
				local label = string.format("#%s · %s", tostring(item.id), tostring(item.title))
				table.insert(choices, label)
				map[label] = item
			end
			vim.ui.select(choices, { prompt = "Select milestone:" }, function(choice)
				if choice == nil then return end
				issue_state.fields.milestone = choice == "(none)" and nil or map[choice]
				render_meta(issue_state)
			end)
		end)
	end)
end

---@param issue_state GiteaCreateIssueState
---@param content string
local function set_body(issue_state, content)
	if not valid_buf(issue_state.layout.desc_buf) then return false end
	local lines = vim.split(tostring(content or ""), "\n", { plain = true })
	vim.api.nvim_buf_set_lines(issue_state.layout.desc_buf, 0, -1, false, lines)
	return true
end

---@param issue_state GiteaCreateIssueState
local function apply_template_from_picker(issue_state)
	local templates, list_err = template_store.list()
	if list_err then notify_error(list_err) return end
	if templates == nil or #templates == 0 then notify_warn("No templates found") return end
	vim.ui.select(templates, {
		prompt = "Apply template",
		kind = "atlas_gitea_templates",
		format_item = function(item) return tostring((item and item.name) or "") end,
	}, function(selected)
		if selected == nil then return end
		local content, read_err = template_store.read(tostring(selected.name or ""))
		if read_err then notify_error(read_err) return end
		local function apply()
			if not set_body(issue_state, content or "") then
				notify_error("Issue body buffer is not available")
				return
			end
			notify_info(string.format("Applied template: %s", tostring(selected.name)))
		end
		if vim.trim(get_body(issue_state)) == "" then
			apply()
			return
		end
		vim.ui.input({ prompt = "Description is not empty. Replace with template? [y/N]: " }, function(input)
			if input and vim.trim(tostring(input)):lower() == "y" then apply() end
		end)
	end)
end

---@param issue_state GiteaCreateIssueState
local function save_body_as_template(issue_state)
	local body = vim.trim(get_body(issue_state))
	if body == "" then notify_warn("Description is empty") return end
	vim.ui.input({ prompt = "Template name: " }, function(input)
		if input == nil then return end
		local name = vim.trim(tostring(input))
		if name == "" then notify_warn("Template name is required") return end
		local ok, write_err, existed, normalized_name = template_store.write(name, body, { overwrite = false })
		if ok then
			notify_info(string.format("Created template %s", tostring(normalized_name or name)))
			return
		end
		if existed then
			vim.ui.input({
				prompt = string.format('Template "%s" exists. Overwrite? [y/N]: ', tostring(normalized_name or name)),
			}, function(confirm)
				if confirm == nil or vim.trim(tostring(confirm)):lower() ~= "y" then return end
				local ow_ok, ow_err, _, final_name = template_store.write(name, body, { overwrite = true })
				if not ow_ok then notify_error(ow_err or "Failed to overwrite template") return end
				notify_info(string.format("Updated template %s", tostring(final_name or normalized_name or name)))
			end)
			return
		end
		notify_error(write_err or "Failed to create template")
	end)
end

---@param issue_state GiteaCreateIssueState
local function open_templates_menu(issue_state)
	vim.ui.select(
		{ { id = "apply", label = "Apply template" }, { id = "save", label = "Save current description as template" } },
		{ prompt = "Issue templates", kind = "atlas_gitea_templates_menu", format_item = function(i) return i.label end },
		function(selected)
			if selected == nil then return end
			if selected.id == "apply" then apply_template_from_picker(issue_state) return end
			save_body_as_template(issue_state)
		end
	)
end

---@param issue_state GiteaCreateIssueState
local function submit(issue_state)
	if issue_state.is_submitting then return end

	local title = get_title(issue_state)
	if title == "" then notify_warn("Title is required") return end

	-- Gitea create_issue takes label IDs (integers), not names
	local label_ids = {}
	for _, label in ipairs(issue_state.fields.labels) do
		if type(label.id) == "number" then
			table.insert(label_ids, label.id)
		end
	end

	local assignee_logins = {}
	for _, assignee in ipairs(issue_state.fields.assignees) do
		table.insert(assignee_logins, tostring(assignee.account_id or ""))
	end

	issue_state.is_submitting = true
	spinner.start("Creating issue…")

	local issues_api = require("atlas.issues.providers.gitea.api.issues")
	issues_api.create_issue({
		repo_slug = issue_state.fields.repo_slug,
		title = title,
		body = get_body(issue_state),
		labels = #label_ids > 0 and label_ids or nil,
		assignees = #assignee_logins > 0 and assignee_logins or nil,
		milestone = issue_state.fields.milestone and issue_state.fields.milestone.id or nil,
	}, function(result, err)
		vim.schedule(function()
			issue_state.is_submitting = false
			spinner.stop()
			if err then
				notify_error("Create issue failed: " .. tostring(err))
				if type(issue_state.on_done) == "function" then issue_state.on_done(nil, err) end
				return
			end
			local url = result and result.url or nil
			if type(url) == "string" and url ~= "" then
				notify_info("Issue created: " .. url)
				pcall(vim.fn.setreg, "+", url)
			else
				notify_info("Issue created")
			end
			if type(issue_state.on_done) == "function" then issue_state.on_done(result, nil) end
			close(issue_state)
		end)
	end)
end

---@class GiteaIssueEditorOpts
---@field repo_slug string
---@field on_done fun(result: table|nil, err: string|nil)|nil

---@param opts GiteaIssueEditorOpts
function M.open(opts)
	if type(opts) ~= "table" then
		notify_warn("create_issue.open: missing options")
		return
	end

	local repo_slug = tostring(opts.repo_slug or "")
	if repo_slug == "" then
		notify_error("create_issue.open: repo_slug is required")
		return
	end

	require("atlas.ui.shared.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()

	---@type GiteaCreateIssueState
	local issue_state = {
		fields = {
			repo_slug = repo_slug,
			title = "",
			body = "",
			labels = {},
			assignees = {},
			milestone = nil,
		},
		layout = {},
		content_width = 80,
		is_submitting = false,
		pickers = default_pickers(repo_slug),
		on_done = opts.on_done,
	}

	form.open(issue_state, {
		title = " Create Issue ",
		min_height = 22,
		meta_height = 3,
		title_winbar = "Title",
		desc_winbar = "Description",
		initial_title = "",
		initial_body = "",
		close = function() confirm_close(issue_state) end,
		submit = function() submit(issue_state) end,
		meta = function() return meta_rows(issue_state) end,
		keymaps = {
			{
				key = "ga",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "assignees",
				show_in_footer = true,
				action = function() pick_assignees(issue_state) end,
			},
			{
				key = "gl",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "labels",
				show_in_footer = true,
				action = function() pick_labels(issue_state) end,
			},
			{
				key = "gm",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "milestone",
				show_in_footer = true,
				action = function() pick_milestone(issue_state) end,
			},
			{
				key = "gt",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "templates",
				show_in_footer = true,
				action = function() open_templates_menu(issue_state) end,
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
