local M = {}

local icons = require("atlas.ui.shared.icons")
local footer = require("atlas.ui.components.footer")
local async_picker = require("atlas.ui.components.async_picker")
local multi_select = require("atlas.ui.popups.multi_select")
local issues_api = require("atlas.issues.providers.gitlab.api.issues")
local users_api = require("atlas.issues.providers.gitlab.api.users")
local labels_api = require("atlas.issues.providers.gitlab.api.labels")
local normalizer = require("atlas.issues.providers.gitlab.api.mapper")

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
local function issue_path(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local path = tostring(raw.project_path or "")
	if path ~= "" then
		return path
	end
	local from_key, _ = normalizer.parse_key(tostring(issue.key or ""))
	return from_key
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
			local key = tostring(ctx.issue.key or "")
			footer.notify("loading", string.format("Closing %s...", key))
			issues_api.set_state(key, "close", function(ok, err)
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
			local key = tostring(ctx.issue.key or "")
			footer.notify("loading", string.format("Reopening %s...", key))
			issues_api.set_state(key, "reopen", function(ok, err)
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
		label = "Toggle Open/Closed",
		is_available = has_issue,
		run = function(ctx, done)
			local key = tostring(ctx.issue.key or "")
			local target = ctx.issue.status_id == "closed" and "reopen" or "close"
			local label = target == "close" and "Closing" or "Reopening"
			footer.notify("loading", string.format("%s %s...", label, key))
			issues_api.set_state(key, target, function(ok, err)
				if not ok then
					footer.notify("error", err or (label .. " failed"))
					done(nil, err or (label .. " failed"))
					return
				end
				local msg = target == "close" and "Closed" or "Reopened"
				footer.notify("success", string.format("%s %s", msg, key), 1200)
				done({ changed_issue_key = key, message = msg }, nil)
			end)
		end,
	},
	{
		id = "assign",
		label = "Edit Assignees",
		is_available = has_issue,
		run = function(ctx, done)
			local issue = ctx.issue
			local key = tostring(issue.key or "")
			local path = issue_path(issue)
			if path == "" then
				done(nil, "Could not determine project path")
				return
			end

			footer.notify("loading", "Loading members...")
			users_api.list_members(path, "", function(members, err)
				if err or members == nil then
					footer.notify("error", err or "Failed to load members")
					done(nil, err or "Failed to load members")
					return
				end
				footer.notify("info", "", 0)

				if #members == 0 then
					done(nil, "No assignable members")
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

				multi_select.open({
					items = members,
					selected = vim.deepcopy(original),
					key = function(item)
						return tostring(item.id or item.account_id or "")
					end,
					format = function(item)
						return string.format(
							"%s %s (@%s)",
							icons.general("user"),
							item.display_name or item.account_id or item.name or item.username,
							item.account_id or item.username
						)
					end,
					prompt = string.format("Assignees for %s", key),
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
							done({ changed_issue_key = nil, message = "No changes" }, nil)
							return
						end

						footer.notify("loading", string.format("Updating assignees on %s...", key))
						issues_api.set_assignee_ids(key, final_ids, function(ok, set_err)
							if not ok then
								footer.notify("error", set_err or "Failed")
								done(nil, set_err or "Failed")
								return
							end
							local msg = string.format("%d assignee(s)", #final_ids)
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
		is_available = has_issue,
		run = function(ctx, done)
			local issue = ctx.issue
			local key = tostring(issue.key or "")
			local path = issue_path(issue)
			if path == "" then
				done(nil, "Could not determine project path")
				return
			end

			footer.notify("loading", "Loading labels...")
			labels_api.list(path, function(labels, err)
				if err or labels == nil then
					footer.notify("error", err or "Failed to load labels")
					done(nil, err or "Failed to load labels")
					return
				end
				footer.notify("info", "", 0)
				if #labels == 0 then
					done(nil, "No labels available")
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

				multi_select.open({
					items = labels,
					selected = vim.deepcopy(original),
					key = function(item)
						return tostring(item.name or "")
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
		id = "search",
		label = "Search Issues",
		is_available = function()
			return true, nil
		end,
		run = function(_, done)
			local prev_items = nil
			async_picker.open({
				title = "Search GitLab Issues",
				prompt = "Search issues",
				debounce_ms = 250,
				identifier = "gitlab_issue_picker_search",
				cache_ttl_ms = 30000,
				fetch_on_open = false,
				format_item = function(item)
					return string.format("%s %s", icons.fallback(), tostring(item.label or ""))
				end,
				fetch = function(fetch_ctx, fetch_done)
					local q = vim.trim(fetch_ctx.query)
					if q == "" then
						fetch_done(prev_items or {}, nil)
						return
					end
					issues_api.search_issues_picker(q, {}, function(items, err)
						if fetch_ctx.signal.cancelled then
							return
						end
						if err or items == nil then
							fetch_done(nil, err or "Search failed")
							return
						end
						local picker_items = {}
						for _, it in ipairs(items) do
							table.insert(picker_items, {
								id = it.key,
								label = string.format("%s - %s", it.key, it.summary),
								secondary = it.key,
								value = it,
							})
						end
						prev_items = picker_items
						fetch_done(picker_items, nil)
					end)
				end,
				on_select = function(item)
					local key = item.value and item.value.key or item.id
					if not key or key == "" then
						done(nil, "Selected issue is missing key")
						return
					end
					require("atlas.issues.ui.main.controller").refresh_issue(key)
					done({ changed_issue_key = key, message = string.format("Opened %s", key) }, nil)
				end,
				on_cancel = function()
					done({ changed_issue_key = nil, message = "Search cancelled" }, nil)
				end,
			})
		end,
	},
	{
		id = "create_issue",
		label = "Create Issue",
		is_available = function()
			return true, nil
		end,
		run = function(ctx, done)
			ctx = ctx or {}

			local function resolve_path()
				if type(ctx.project_path) == "string" and ctx.project_path ~= "" then
					return ctx.project_path
				end
				if has_issue(ctx) then
					local p = issue_path(ctx.issue)
					if p ~= "" then
						return p
					end
				end
				local ok_git, git = pcall(require, "atlas.core.git")
				if ok_git then
					local root = git.repo_root and git.repo_root(nil) or nil
					if root then
						local remote = git.remote_url and git.remote_url(root, "origin") or nil
						local info = remote and git.parse_remote_url and git.parse_remote_url(remote) or nil
						if info and info.provider == "gitlab" and info.slug and info.slug ~= "" then
							return info.slug
						end
					end
				end
				return ""
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
						if result and type(result.key) == "string" and result.key ~= "" then
							require("atlas.issues.ui.main.controller").refresh_current_view()
						end
						done({
							changed_issue_key = result and result.key or nil,
							message = (result and result.url) or "Issue created",
						}, nil)
					end,
				})
			end

			local resolved = resolve_path()
			if resolved ~= "" then
				open_editor(resolved)
				return
			end

			vim.ui.input({ prompt = "Project (group/project): " }, function(input)
				if input == nil then
					done({ changed_issue_key = nil, message = "Cancelled" }, nil)
					return
				end
				local path = vim.trim(tostring(input))
				if path == "" then
					done({ changed_issue_key = nil, message = "Cancelled" }, nil)
					return
				end
				open_editor(path)
			end)
		end,
	},
	{
		id = "browse_issue",
		label = "Open Issue In Browser",
		hidden = true,
		is_available = has_issue,
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
		is_available = has_issue,
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
		is_available = has_issue,
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
	{
		id = "toggle_subscription",
		label = "Toggle subscription",
		is_available = function(ctx)
			if not has_issue(ctx) then
				return false, "No issue selected"
			end
			local raw = type(ctx.issue._raw) == "table" and ctx.issue._raw or {}
			local iid = tonumber(raw.iid)
			local path = tostring(raw.project_path or "")
			if iid == nil or path == "" then
				return false, "Invalid issue identifier"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local service = require("atlas.issues.providers.gitlab.api.service")
			local issue = ctx.issue
			local raw = type(issue._raw) == "table" and issue._raw or {}
			local path = tostring(raw.project_path or "")
			local iid = tonumber(raw.iid)
			local action = issue.is_subscribed == true and "unsubscribe" or "subscribe"
			local endpoint = string.format("/projects/%s/issues/%d/%s", service.url_encode(path), iid, action)
			footer.notify("loading", issue.is_subscribed and "Unsubscribing..." or "Subscribing...")
			service.request("POST", endpoint, nil, function(result, err)
				if err then
					footer.notify("error", tostring(err))
					done(nil, tostring(err))
					return
				end
				local subscribed = type(result) == "table" and result.subscribed
				if type(subscribed) ~= "boolean" then
					subscribed = action == "subscribe"
				end
				issue.is_subscribed = subscribed == true
				footer.notify("success", issue.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
				done(
					{ changed_issue_key = issue.key, message = issue.is_subscribed and "Subscribed" or "Unsubscribed" },
					nil
				)
			end)
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
