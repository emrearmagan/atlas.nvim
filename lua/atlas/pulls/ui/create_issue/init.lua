local M = {}

local layout = require("atlas.pulls.ui.create_issue.layout")
local renderer = require("atlas.pulls.ui.create_issue.renderer")
local state = require("atlas.pulls.ui.create_issue.state")
local spinner = require("atlas.ui.popups.spinner")

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

local function get_title()
	if not valid_buf(state.layout.title_buf) then
		return ""
	end
	local lines = vim.api.nvim_buf_get_lines(state.layout.title_buf, 0, -1, false)
	return vim.trim(table.concat(lines, " "))
end

local function get_body()
	if not valid_buf(state.layout.desc_buf) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(state.layout.desc_buf, 0, -1, false), "\n")
end

local function close()
	spinner.stop()
	layout.close(state.layout)
	state.reset()
end

local function confirm_close()
	local title = get_title()
	local body = get_body()
	if title == "" and body == "" then
		close()
		return
	end

	vim.ui.input({ prompt = "Discard issue draft? [y/N]: " }, function(input)
		if type(input) == "string" and input:match("^[yY]") then
			close()
		end
	end)
end

--------------------------------------------------------------------------------
-- Pickers
--------------------------------------------------------------------------------

---@param login string
local function login_in_list(login, list)
	for _, item in ipairs(list) do
		if item.login == login then
			return true
		end
	end
	return false
end

---@param name string
local function label_in_list(name, list)
	for _, item in ipairs(list) do
		if item.name == name then
			return true
		end
	end
	return false
end

local function pick_assignees()
	if type(state.pickers.list_assignees) ~= "function" then
		notify_warn("Assignee picker is not available")
		return
	end

	spinner.start("Loading assignees…")
	state.pickers.list_assignees(function(items, err)
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

			local function loop()
				local choices = { "✓ Done" }
				local map = { ["✓ Done"] = nil }
				for _, item in ipairs(items) do
					local marker = login_in_list(item.login, state.fields.assignees) and "[x] " or "[ ] "
					local label =
						string.format("%s@%s%s", marker, item.login, item.name and (" — " .. item.name) or "")
					table.insert(choices, label)
					map[label] = item
				end

				vim.ui.select(choices, { prompt = "Toggle assignees (Done to finish):" }, function(choice)
					if choice == nil or choice == "✓ Done" then
						renderer.render_meta(state)
						return
					end
					local item = map[choice]
					if item == nil then
						return
					end
					if login_in_list(item.login, state.fields.assignees) then
						local kept = {}
						for _, a in ipairs(state.fields.assignees) do
							if a.login ~= item.login then
								table.insert(kept, a)
							end
						end
						state.fields.assignees = kept
					else
						table.insert(state.fields.assignees, item)
					end
					loop()
				end)
			end

			loop()
		end)
	end)
end

local function pick_labels()
	if type(state.pickers.list_labels) ~= "function" then
		notify_warn("Label picker is not available")
		return
	end

	spinner.start("Loading labels…")
	state.pickers.list_labels(function(items, err)
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

			local function loop()
				local choices = { "✓ Done" }
				local map = {}
				for _, item in ipairs(items) do
					local marker = label_in_list(item.name, state.fields.labels) and "[x] " or "[ ] "
					local label = marker .. tostring(item.name)
					table.insert(choices, label)
					map[label] = item
				end

				vim.ui.select(choices, { prompt = "Toggle labels (Done to finish):" }, function(choice)
					if choice == nil or choice == "✓ Done" then
						renderer.render_meta(state)
						return
					end
					local item = map[choice]
					if item == nil then
						return
					end
					if label_in_list(item.name, state.fields.labels) then
						local kept = {}
						for _, l in ipairs(state.fields.labels) do
							if l.name ~= item.name then
								table.insert(kept, l)
							end
						end
						state.fields.labels = kept
					else
						table.insert(state.fields.labels, item)
					end
					loop()
				end)
			end

			loop()
		end)
	end)
end

local function pick_milestone()
	if type(state.pickers.list_milestones) ~= "function" then
		notify_warn("Milestone picker is not available")
		return
	end

	spinner.start("Loading milestones…")
	state.pickers.list_milestones(function(items, err)
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
					state.fields.milestone = nil
				else
					state.fields.milestone = map[choice]
				end
				renderer.render_meta(state)
			end)
		end)
	end)
end

--------------------------------------------------------------------------------
-- Submit
--------------------------------------------------------------------------------

local function submit()
	if state.is_submitting then
		return
	end

	if type(state.on_submit) ~= "function" then
		notify_error("Submit handler not configured")
		return
	end

	local title = get_title()
	if title == "" then
		notify_warn("Title is required")
		return
	end

	local body = get_body()

	local label_names = {}
	for _, l in ipairs(state.fields.labels) do
		table.insert(label_names, l.name)
	end

	local assignee_logins = {}
	for _, a in ipairs(state.fields.assignees) do
		table.insert(assignee_logins, a.login)
	end

	state.is_submitting = true
	spinner.start("Creating issue…")

	state.on_submit({
		repo_slug = state.fields.repo_slug,
		title = title,
		body = body,
		labels = label_names,
		assignees = assignee_logins,
		milestone = state.fields.milestone and state.fields.milestone.number or nil,
	}, function(result, err)
		vim.schedule(function()
			state.is_submitting = false
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

			close()
		end)
	end)
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

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

	state.reset()
	state.fields.repo_slug = tostring(opts.repo_slug or "")
	state.fields.title = tostring(opts.initial_title or "")
	state.fields.body = tostring(opts.initial_body or "")
	state.fields.labels = type(opts.initial_labels) == "table" and opts.initial_labels or {}
	state.fields.assignees = type(opts.initial_assignees) == "table" and opts.initial_assignees or {}
	state.fields.milestone = opts.initial_milestone
	state.pickers = type(opts.pickers) == "table" and opts.pickers or {}
	state.on_submit = opts.on_submit

	layout.open(state)

	if valid_buf(state.layout.desc_buf) and state.fields.body ~= "" then
		vim.api.nvim_buf_set_lines(
			state.layout.desc_buf,
			0,
			-1,
			false,
			vim.split(state.fields.body, "\n", { plain = true })
		)
	end

	renderer.render_meta(state)

	layout.setup(state, {
		confirm_close = confirm_close,
		submit = submit,
		pick_assignees = pick_assignees,
		pick_labels = pick_labels,
		pick_milestone = pick_milestone,
	})

	vim.schedule(function()
		if vim.api.nvim_get_current_buf() == state.layout.title_buf then
			vim.cmd("startinsert!")
		end
	end)
end

return M
