local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.picker")
local statusline = require("atlas.ui.statusline")
local issues_api = require("atlas.issues.providers.gitlab.api.issues")
local users_api = require("atlas.issues.providers.gitlab.api.users")
local labels_api = require("atlas.issues.providers.gitlab.api.labels")
local normalizer = require("atlas.issues.providers.gitlab.api.mapper")

---@param ctx AtlasIssueActionContext
---@return boolean
local function has_issue(ctx)
	local issue = ctx.issue
	return issue ~= nil and tostring(issue.key or "") ~= ""
end

---@param issue Issue
---@return string
local function issue_path(issue)
	local raw = issue._raw or {}
	local path = tostring(raw.project_path or "")
	if path ~= "" then
		return path
	end
	local from_key, _ = normalizer.parse_key(tostring(issue.key or ""))
	return from_key
end

---@type AtlasIssueAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasIssueAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function close_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	return assert(ctx.issue).status_id ~= "closed", "Issue is already closed"
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function close(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	statusline.notify("loading", string.format("Closing %s...", key))
	issues_api.set_state(key, "close", function(ok, err)
		if not ok then
			statusline.notify("error", err or "Close failed")
			done(nil, err or "Close failed")
			return
		end
		statusline.notify("success", string.format("Closed %s", key), 1200)
		done({ issue_key = key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function reopen_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	return assert(ctx.issue).status_id == "closed", "Issue is not closed"
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function reopen(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	statusline.notify("loading", string.format("Reopening %s...", key))
	issues_api.set_state(key, "reopen", function(ok, err)
		if not ok then
			statusline.notify("error", err or "Reopen failed")
			done(nil, err or "Reopen failed")
			return
		end
		statusline.notify("success", string.format("Reopened %s", key), 1200)
		done({ issue_key = key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean
local function transition_available(ctx)
	return has_issue(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function transition(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local target = issue.status_id == "closed" and "reopen" or "close"
	local label = target == "close" and "Closing" or "Reopening"
	statusline.notify("loading", string.format("%s %s...", label, key))
	issues_api.set_state(key, target, function(ok, err)
		if not ok then
			statusline.notify("error", err or (label .. " failed"))
			done(nil, err or (label .. " failed"))
			return
		end
		local msg = target == "close" and "Closed" or "Reopened"
		statusline.notify("success", string.format("%s %s", msg, key), 1200)
		done({ issue_key = key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean
local function assign_available(ctx)
	return has_issue(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function assign(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local path = issue_path(issue)
	if path == "" then
		local err = "Could not determine project path"
		statusline.notify("error", err)
		done(nil, err)
		return
	end

	statusline.notify("loading", "Loading members...")
	users_api.list_members(path, "", function(members, err)
		if err or members == nil then
			statusline.notify("error", err or "Failed to load members")
			done(nil, err or "Failed to load members")
			return
		end
		statusline.clear_notice()

		if #members == 0 then
			local err = "No assignable members"
			statusline.notify("warn", err)
			done(nil, err)
			return
		end

		local raw = issue._raw or {}
		local original = {}
		local original_set = {}
		for _, a in ipairs(raw.assignees or {}) do
			local id = tonumber(a.id)
			if id then
				table.insert(original, { id = id, username = a.username, name = a.name or a.username })
				original_set[id] = true
			end
		end

		picker.multi_select({
			items = members,
			selected = vim.deepcopy(original),
			key = function(item)
				return tostring(item.id or item.account_id or "")
			end,
			format_item = function(item)
				return string.format(
					"%s %s (@%s)",
					icons.general("user"),
					item.display_name or item.account_id or item.name or item.username,
					item.account_id or item.username
				)
			end,
			title = string.format("Assignees for %s", key),
			on_done = function(selected)
				local final_ids = {}
				local final_set = {}
				for _, it in ipairs(selected) do
					local id = tonumber(it.id)
					if id then
						table.insert(final_ids, id)
						final_set[id] = true
					end
				end

				local changed = false
				if #final_ids ~= #original then
					changed = true
				else
					for id, _ in pairs(original_set) do
						if not final_set[id] then
							changed = true
							break
						end
					end
				end

				if not changed then
					done(nil, nil)
					return
				end

				statusline.notify("loading", string.format("Updating assignees on %s...", key))
				issues_api.set_assignee_ids(key, final_ids, function(ok, set_err)
					if not ok then
						statusline.notify("error", set_err or "Failed")
						done(nil, set_err or "Failed")
						return
					end
					local msg = string.format("%d assignee(s)", #final_ids)
					statusline.notify("success", msg, 1200)
					done({ issue_key = key }, nil)
				end)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean
local function labels_available(ctx)
	return has_issue(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function labels(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local path = issue_path(issue)
	if path == "" then
		local err = "Could not determine project path"
		statusline.notify("error", err)
		done(nil, err)
		return
	end

	statusline.notify("loading", "Loading labels...")
	labels_api.list(path, function(all_labels, err)
		if err or all_labels == nil then
			statusline.notify("error", err or "Failed to load labels")
			done(nil, err or "Failed to load labels")
			return
		end
		statusline.clear_notice()
		if #all_labels == 0 then
			local err = "No labels available"
			statusline.notify("warn", err)
			done(nil, err)
			return
		end

		local raw = issue._raw or {}
		local original = {}
		local original_set = {}
		for _, name in ipairs(raw.label_names or {}) do
			if type(name) == "string" and name ~= "" then
				table.insert(original, { name = name })
				original_set[name] = true
			end
		end

		picker.multi_select({
			items = all_labels,
			selected = vim.deepcopy(original),
			key = function(item)
				return tostring(item.name or "")
			end,
			format_item = function(item)
				return tostring(item.name or "")
			end,
			title = string.format("Labels for %s", key),
			on_done = function(selected)
				local selected_set = {}
				for _, it in ipairs(selected) do
					selected_set[it.name] = true
				end
				local adds, removes = {}, {}
				for name, _ in pairs(selected_set) do
					if not original_set[name] then
						table.insert(adds, name)
					end
				end
				for name, _ in pairs(original_set) do
					if not selected_set[name] then
						table.insert(removes, name)
					end
				end
				if #adds == 0 and #removes == 0 then
					done(nil, nil)
					return
				end

				statusline.notify("loading", string.format("Updating labels on %s...", key))
				issues_api.update_labels(key, { add = adds, remove = removes }, function(ok, set_err)
					if not ok then
						statusline.notify("error", set_err or "Failed")
						done(nil, set_err or "Failed")
						return
					end
					local msg = string.format("+%d / -%d label(s)", #adds, #removes)
					statusline.notify("success", msg, 1200)
					done({ issue_key = key }, nil)
				end)
			end,
		})
	end)
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search(_, done)
	local prev_items = nil
	picker.search({
		title = "Search GitLab Issues",
		fetch_on_open = false,
		format_item = function(item)
			return string.format("%s %s", icons.fallback(), tostring(item.label or ""))
		end,
		preview_item = function(item, done)
			local issue = item.value
			return issues_api.get_issue(issue.key, {}, function(detail, err)
				if err then
					done({ title = issue.key, lines = { err } })
					return
				end
				local description = vim.trim(tostring(detail and detail.description or ""))
				done({
					title = issue.key,
					lines = vim.split(description ~= "" and description or "No description", "\n", { plain = true }),
				})
			end)
		end,
		fetch = function(query, fetch_done)
			local q = vim.trim(query)
			if q == "" then
				fetch_done(prev_items or {}, nil)
				return
			end
			return issues_api.search_issues_picker(q, {}, function(items, err)
				if err or items == nil then
					fetch_done(nil, err or "Search failed")
					return
				end
				local picker_items = {}
				for _, it in ipairs(items) do
					table.insert(picker_items, {
						id = it.key,
						label = string.format("%s - %s", it.key, it.title),
						value = it,
					})
				end
				prev_items = picker_items
				fetch_done(picker_items, nil)
			end)
		end,
		on_select = function(item)
			local url = item.value and item.value.url
			if not url or url == "" then
				local err = "Selected issue is missing URL"
				statusline.notify("error", err)
				done(nil, err)
				return
			end
			require("atlas.commands.open").open(url)
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(ctx, done)
	local resolved = ctx.project_path or ""
	if resolved == "" and has_issue(ctx) then
		resolved = issue_path(assert(ctx.issue))
	end
	if resolved == "" then
		local git = require("atlas.core.git")
		local root = git.repo_root(nil)
		if root then
			local remote = git.remote_url(root, "origin")
			local info = remote and git.parse_remote_url(remote, "issues") or nil
			if info and info.provider == "gitlab" and info.slug and info.slug ~= "" then
				resolved = info.slug
			end
		end
	end

	local function open_editor(path)
		local create_issue_ui = require("atlas.issues.create.gitlab.issue")
		create_issue_ui.open({
			project_path = path,
			on_done = function(result, err)
				if err then
					done(nil, tostring(err))
					return
				end
				if result == nil then
					done(nil, nil)
					return
				end
				done({ issue_key = result.key }, nil)
			end,
		})
	end

	if resolved ~= "" then
		open_editor(resolved)
		return
	end

	vim.ui.input({ prompt = "Project (group/project): " }, function(input)
		if input == nil then
			done(nil, nil)
			return
		end
		local path = vim.trim(tostring(input))
		if path == "" then
			done(nil, nil)
			return
		end
		open_editor(path)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	local issue = assert(ctx.issue)
	local raw = issue._raw or {}
	local iid = tonumber(raw.iid)
	local path = tostring(raw.project_path or "")
	if iid == nil or path == "" then
		return false, "Invalid issue identifier"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local service = require("atlas.providers.gitlab.client").issues
	local issue = assert(ctx.issue)
	local raw = issue._raw or {}
	local path = tostring(raw.project_path or "")
	local iid = tonumber(raw.iid)
	local action = issue.is_subscribed == true and "unsubscribe" or "subscribe"
	local endpoint = string.format("/projects/%s/issues/%d/%s", service.url_encode(path), iid, action)
	statusline.notify("loading", issue.is_subscribed and "Unsubscribing..." or "Subscribing...")
	service.request("POST", endpoint, nil, function(result, err)
		if err then
			statusline.notify("error", tostring(err))
			done(nil, tostring(err))
			return
		end
		local subscribed = type(result) == "table" and result.subscribed
		if type(subscribed) ~= "boolean" then
			subscribed = action == "subscribe"
		end
		issue.is_subscribed = subscribed == true
		statusline.notify("success", issue.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
		done({ issue_key = issue.key }, nil)
	end)
end

register({ id = "close", label = "Close Issue", is_available = close_available, run = close })
register({ id = "reopen", label = "Reopen Issue", is_available = reopen_available, run = reopen })
register({
	id = "transition",
	label = "Toggle Open/Closed",
	is_available = transition_available,
	run = transition,
})
register({ id = "assign", label = "Edit Assignees", is_available = assign_available, run = assign })
register({ id = "labels", label = "Edit Labels", is_available = labels_available, run = labels })
register({ id = "search", label = "Search Issues", run = search })
register({ id = "create_issue", label = "Create Issue", run = create_issue })
register(actions.manage_templates)
register(actions.browse_issue)
register(actions.copy_issue_key)
register(actions.copy_issue_url)
register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})

---@param id AtlasGitLabIssueActionId
---@return AtlasIssueAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
