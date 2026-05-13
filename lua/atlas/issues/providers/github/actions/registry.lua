local M = {}

local icons = require("atlas.ui.shared.icons")
local footer = require("atlas.ui.components.footer")
local multi_select = require("atlas.ui.popups.multi_select")
local issues_api = require("atlas.issues.providers.github.api.issues")
local users_api = require("atlas.issues.providers.github.api.users")
local normalizer = require("atlas.issues.providers.github.api.normalizer")

---@param ctx table
---@return boolean
local function has_issue(ctx)
	local issue = type(ctx) == "table" and ctx.issue or nil
	if type(issue) ~= "table" then
		return false
	end
	local key = tostring(issue.key or "")
	return key ~= ""
end

---@param issue Issue
---@return string
local function issue_slug(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local slug = tostring(raw.slug or "")
	if slug ~= "" then
		return slug
	end
	local from_key, _ = normalizer.parse_key(tostring(issue.key or ""))
	return from_key
end

---@param ctx table
---@return string|nil slug, string|nil err
local function create_issue_slug(ctx)
	local explicit = tostring(type(ctx) == "table" and ctx.repo_slug or "")
	if explicit ~= "" then
		return explicit, nil
	end

	if has_issue(ctx) then
		local slug = issue_slug(ctx.issue)
		if slug ~= "" then
			return slug, nil
		end
	end

	return nil, "Could not determine repository"
end

---@return string
local function current_search()
	local state = require("atlas.issues.state")
	local view = state.active_view or state.current_view or {}
	return tostring(view.search or "")
end

---@param id string
---@param ctx table
---@param done fun(result: table|nil, err: string|nil)
local function run_action(id, ctx, done)
	local action = M.find(id)
	if action == nil then
		done(nil, string.format("Unknown action: %s", id))
		return
	end
	action.run(ctx, done)
end

local ACTIONS = {
	{
		id = "close",
		label = "Close Issue",
		is_available = function(ctx)
			if not has_issue(ctx) then
				return false, "No issue selected"
			end
			return ctx.issue.status_id ~= "closed", "Issue is already closed"
		end,
		run = function(ctx, done)
			local issue = ctx.issue
			local key = tostring(issue.key or "")
			footer.notify("loading", string.format("Closing %s...", key))
			issues_api.set_state(key, "closed", function(ok, err)
				if not ok then
					footer.notify("error", err or "Close failed")
					done(nil, err or "Close failed")
					return
				end
				footer.notify("success", string.format("Closed %s", key), 1200)
				done({ changed_issue_key = key, message = "Closed" }, nil)
			end)
		end,
	},
	{
		id = "reopen",
		label = "Reopen Issue",
		is_available = function(ctx)
			if not has_issue(ctx) then
				return false, "No issue selected"
			end
			return ctx.issue.status_id == "closed", "Issue is not closed"
		end,
		run = function(ctx, done)
			local issue = ctx.issue
			local key = tostring(issue.key or "")
			footer.notify("loading", string.format("Reopening %s...", key))
			issues_api.set_state(key, "open", function(ok, err)
				if not ok then
					footer.notify("error", err or "Reopen failed")
					done(nil, err or "Reopen failed")
					return
				end
				footer.notify("success", string.format("Reopened %s", key), 1200)
				done({ changed_issue_key = key, message = "Reopened" }, nil)
			end)
		end,
	},
	{
		id = "transition",
		label = "Transition Issue",
		hidden = true,
		is_available = function(ctx)
			if not has_issue(ctx) then
				return false, "No issue selected"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local issue = ctx.issue
			local key = tostring(issue.key or "")
			local is_closed = tostring(issue.status_id or "") == "closed"
			local action_id = is_closed and "reopen" or "close"
			local verb = is_closed and "Reopen" or "Close"

			vim.ui.input({
				prompt = string.format("%s issue %s? [y/N]: ", verb, key),
			}, function(input)
				if input == nil or vim.trim(tostring(input)):lower() ~= "y" then
					done({ changed_issue_key = nil, message = "Transition cancelled" }, nil)
					return
				end

				run_action(action_id, ctx, done)
			end)
		end,
	},
	{
		id = "assign",
		label = "Edit Assignees",
		is_available = function(ctx)
			if not has_issue(ctx) then
				return false, "No issue selected"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local issue = ctx.issue
			local key = tostring(issue.key or "")
			local slug = issue_slug(issue)
			if slug == "" then
				done(nil, "Could not determine repository")
				return
			end

			footer.notify("loading", "Loading users...")
			users_api.get_assignable_users(slug, "", function(users, err)
				if err or users == nil then
					footer.notify("error", err or "Failed to load users")
					done(nil, err or "Failed to load users")
					return
				end
				footer.notify("info", "", 0)

				local items = {}
				for _, u in ipairs(users) do
					table.insert(items, { login = u.account_id, name = u.display_name or u.account_id })
				end
				if #items == 0 then
					done(nil, "No assignable users")
					return
				end

				local raw = issue._raw or {}
				local original = {}
				local original_set = {}
				for _, a in ipairs(raw.assignees or {}) do
					local login = tostring(a.login or "")
					if login ~= "" then
						table.insert(original, { login = login, name = a.name or login })
						original_set[login] = true
					end
				end

				multi_select.open({
					items = items,
					selected = vim.deepcopy(original),
					key = function(item)
						return item.login
					end,
					format = function(item)
						return string.format("%s %s", icons.general("user"), item.name or item.login)
					end,
					prompt = string.format("Assignees for %s", key),
					on_done = function(selected)
						local selected_set = {}
						for _, it in ipairs(selected) do
							selected_set[it.login] = true
						end

						local adds, removes = {}, {}
						for login, _ in pairs(selected_set) do
							if not original_set[login] then
								table.insert(adds, login)
							end
						end
						for login, _ in pairs(original_set) do
							if not selected_set[login] then
								table.insert(removes, login)
							end
						end

						if #adds == 0 and #removes == 0 then
							done({ changed_issue_key = nil, message = "No changes" }, nil)
							return
						end

						footer.notify("loading", string.format("Updating assignees on %s...", key))
						issues_api.update_assignees(key, { add = adds, remove = removes }, function(ok, set_err)
							if not ok then
								footer.notify("error", set_err or "Failed")
								done(nil, set_err or "Failed")
								return
							end
							local msg = string.format("+%d / -%d assignee(s)", #adds, #removes)
							footer.notify("success", msg, 1200)
							done({ changed_issue_key = key, message = msg }, nil)
						end)
					end,
				})
			end)
		end,
	},
	{
		id = "labels",
		label = "Edit Labels",
		is_available = function(ctx)
			if not has_issue(ctx) then
				return false, "No issue selected"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local issue = ctx.issue
			local key = tostring(issue.key or "")
			local slug = issue_slug(issue)
			if slug == "" then
				done(nil, "Could not determine repository")
				return
			end

			footer.notify("loading", "Loading labels...")
			issues_api.list_labels(slug, function(labels, err)
				if err or labels == nil then
					footer.notify("error", err or "Failed to load labels")
					done(nil, err or "Failed to load labels")
					return
				end
				footer.notify("info", "", 0)

				local items = {}
				for _, label in ipairs(labels) do
					table.insert(items, { name = label.name, color = label.color })
				end
				if #items == 0 then
					done(nil, "No labels available")
					return
				end

				local raw = issue._raw or {}
				local original = {}
				local original_set = {}
				for _, label in ipairs(raw.labels or {}) do
					local name = tostring(label.name or "")
					if name ~= "" then
						table.insert(original, { name = name, color = label.color })
						original_set[name] = true
					end
				end

				multi_select.open({
					items = items,
					selected = vim.deepcopy(original),
					key = function(item)
						return item.name
					end,
					format = function(item)
						return tostring(item.name or "")
					end,
					prompt = string.format("Labels for %s", key),
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
							done({ changed_issue_key = nil, message = "No changes" }, nil)
							return
						end

						footer.notify("loading", string.format("Updating labels on %s...", key))
						issues_api.update_labels(key, { add = adds, remove = removes }, function(ok, set_err)
							if not ok then
								footer.notify("error", set_err or "Failed")
								done(nil, set_err or "Failed")
								return
							end
							local msg = string.format("+%d / -%d label(s)", #adds, #removes)
							footer.notify("success", msg, 1200)
							done({ changed_issue_key = key, message = msg }, nil)
						end)
					end,
				})
			end)
		end,
	},
	{
		id = "create_issue",
		label = "Create Issue",
		is_available = function(ctx)
			local slug, err = create_issue_slug(ctx or {})
			return slug ~= nil and slug ~= "", err
		end,
			run = function(ctx, done)
				local slug, slug_err = create_issue_slug(ctx or {})
				if slug == nil or slug == "" then
					done(nil, slug_err or "Could not determine repository")
					return
				end

				local create_issue_ui = require("atlas.issues.create.github.issue")

				create_issue_ui.open({
					repo_slug = slug,
					on_done = function(result, err)
						if err then
							done(nil, tostring(err))
							return
						end

						local number = result and result.number
						local key = number and string.format("%s#%s", slug, tostring(number)) or nil
						done({
							changed_issue_key = key,
							message = result and result.url or "Issue created",
						}, nil)
					end,
				})
		end,
	},
	{
		id = "search",
		label = "Search Issues",
		is_available = function()
			return true, nil
		end,
		run = function(_, done)
			local default = vim.trim(current_search())
			if default == "" or not default:find("is:issue") then
				default = "is:issue " .. default
			end
			require("atlas.pulls.providers.github.completion.search").open(vim.trim(default) .. " ")
			done({ changed_issue_key = nil, message = "Searching..." }, nil)
		end,
	},
	{
		id = "browse_issue",
		label = "Open Issue In Browser",
		hidden = true,
		is_available = function(ctx)
			return has_issue(ctx), "No issue selected"
		end,
		run = function(ctx, done)
			local issue = ctx.issue
			local url = tostring(issue.url or "")
			if url == "" then
				done(nil, "No URL")
				return
			end
			vim.ui.open(url)
			done({ changed_issue_key = nil, message = "Opened in browser" }, nil)
		end,
	},
	{
		id = "copy_issue_key",
		label = "Copy Issue Key",
		hidden = true,
		is_available = function(ctx)
			return has_issue(ctx), "No issue selected"
		end,
		run = function(ctx, done)
			local key = tostring(ctx.issue.key or "")
			vim.fn.setreg("+", key)
			vim.fn.setreg('"', key)
			done({ changed_issue_key = nil, message = "Copied issue key" }, nil)
		end,
	},
	{
		id = "copy_issue_url",
		label = "Copy Issue URL",
		hidden = true,
		is_available = function(ctx)
			return has_issue(ctx), "No issue selected"
		end,
		run = function(ctx, done)
			local url = tostring(ctx.issue.url or "")
			if url == "" then
				done(nil, "No URL")
				return
			end
			vim.fn.setreg("+", url)
			vim.fn.setreg('"', url)
			done({ changed_issue_key = nil, message = "Copied issue URL" }, nil)
		end,
	},
}

---@param ctx table
---@return table[]
function M.available(ctx)
	local out = {}
	for _, action in ipairs(ACTIONS) do
		if not action.hidden then
			local ok = action.is_available(ctx)
			if ok then
				table.insert(out, action)
			end
		end
	end

	local issues_cfg = require("atlas.config").options.issues or {}
	local custom_actions = issues_cfg.custom_actions or {}
	local issues_state = require("atlas.issues.state")

	for _, item in ipairs(custom_actions) do
		if type(item) == "table" and type(item.label) == "string" and type(item.run) == "function" then
			table.insert(out, {
				id = tostring(item.id or item.label),
				label = item.label,
				is_available = function(action_ctx)
					if not has_issue(action_ctx) then
						return false, "No issue selected"
					end
					return true, nil
				end,
				run = function(action_ctx, done)
					footer.notify("loading", string.format("Running %s...", tostring(item.label)))

					local done_called = false
					local function custom_done(ok, message)
						if done_called then
							return
						end
						done_called = true

						vim.schedule(function()
							if ok == false then
								footer.notify("error", tostring(message or (item.label .. " failed")))
								done(nil, tostring(message or (item.label .. " failed")))
								return
							end
							footer.notify("success", tostring(message or (item.label .. " done")))
							done({
								changed_issue_key = action_ctx.issue and action_ctx.issue.key or nil,
								message = tostring(message or (item.label .. " done")),
							}, nil)
						end)
					end

					local ok, err = pcall(item.run, action_ctx.issue, {
						issue = action_ctx.issue,
						user = issues_state.current_user,
					}, custom_done)

					if not ok then
						custom_done(false, string.format("Custom action failed: %s", tostring(err)))
					end
				end,
			})
		end
	end

	return out
end

---@param id string
---@return table|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
