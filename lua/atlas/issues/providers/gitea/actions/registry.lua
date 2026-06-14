local M = {}

local icons = require("atlas.ui.shared.icons")
local footer = require("atlas.ui.components.footer")
local multi_select = require("atlas.ui.popups.multi_select")
local issues_api = require("atlas.issues.providers.gitea.api.issues")
local users_api = require("atlas.issues.providers.gitea.api.users")
local mapper = require("atlas.issues.providers.gitea.api.mapper")

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
	local from_key, _ = mapper.parse_key(tostring(issue.key or ""))
	return from_key
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
						table.insert(original, { login = login, name = a.full_name or login })
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
						local new_logins = {}
						for _, it in ipairs(selected) do
							table.insert(new_logins, it.login)
						end

						footer.notify("loading", string.format("Updating assignees on %s...", key))
						issues_api.update_assignees(key, new_logins, function(ok, set_err)
							if not ok then
								footer.notify("error", set_err or "Failed")
								done(nil, set_err or "Failed")
								return
							end
							local msg = string.format("Updated assignees (%d)", #new_logins)
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
			local slug = tostring(type(ctx) == "table" and ctx.repo_slug or "")
			if slug ~= "" then return true, nil end
			if has_issue(ctx) then
				local s = issue_slug(ctx.issue)
				if s ~= "" then return true, nil end
			end
			-- Fall back to git remote detection
			local git = require("atlas.core.git")
			local root = git.repo_root()
			if root then
				local url = git.remote_url(root)
				if url then
					local info = git.parse_remote_url(url)
					if info and info.slug ~= "" then return true, nil end
				end
			end
			return false, "No repository context"
		end,
		run = function(ctx, done)
			local slug = tostring(type(ctx) == "table" and ctx.repo_slug or "")
			if slug == "" and has_issue(ctx) then
				slug = issue_slug(ctx.issue)
			end
			if slug == "" then
				local git = require("atlas.core.git")
				local root = git.repo_root()
				if root then
					local url = git.remote_url(root)
					if url then
						local info = git.parse_remote_url(url)
						if info then slug = info.slug end
					end
				end
			end
			if slug == "" then
				done(nil, "Could not determine repository")
				return
			end

			require("atlas.issues.create.gitea.issue").open({
				repo_slug = slug,
				on_done = function(result, err)
					if err then
						done(nil, err)
						return
					end
					local number = result and result.number
					local new_key = number and string.format("%s#%s", slug, tostring(number)) or nil
					done({ changed_issue_key = new_key, message = result and result.url or "Issue created" }, nil)
				end,
			})
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
			local url = tostring(ctx.issue.url or "")
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
