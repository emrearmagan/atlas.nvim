local M = {}

local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")
local query = require("atlas.issues.providers.forge.query")

---@param provider_id ForgeProviderId
---@return table
function M.new(provider_id)
	local api = require("atlas.issues.providers.forge." .. provider_id .. ".api")
	local issues = api.issues
	local comments = api.comments

	local function resolve_view(view, on_done)
		if not view.current_repo then
			on_done(view)
			return nil
		end
		return git.local_repository(vim.fn.getcwd(), function(target)
			local resolved = vim.tbl_extend("force", {}, view)
			if target and target.provider == provider_id then
				resolved.repo = target.repo_full_name
			end
			on_done(resolved)
		end)
	end

	local function fetch_issues(view, opts, on_done)
		local requests = request_scope.new()
		requests.run(function(done)
			return resolve_view(view, done)
		end, function(resolved)
			local search = query.resolve(resolved)
			requests.run(function(done)
				return issues.list(resolved, opts, done)
			end, function(page, err)
				if err then
					on_done({ items = {}, query = search }, err)
					return
				end
				local pinned, rest = {}, {}
				for _, issue in ipairs(page.items) do
					table.insert(issue.is_pinned and pinned or rest, issue)
				end
				vim.list_extend(pinned, rest)
				page.items = pinned
				page.query = search
				on_done(page, nil)
			end)
		end)
		return requests
	end

	local function fetch_conversation(issue, opts, on_done)
		return api.timeline.list(issue, opts, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local items = {}
			for _, comment in ipairs(result.comments) do
				table.insert(items, {
					id = "comment:" .. comment.id,
					kind = "comment",
					created_at = comment.created_at,
					entity = comment,
				})
			end
			for index, entry in ipairs(result.events) do
				table.insert(items, {
					id = table.concat({ "activity", entry.date or "", index }, ":"),
					kind = "activity",
					created_at = entry.date or "",
					entity = entry,
				})
			end
			-- Timeline responses omit reaction counts; loading them requires one request per comment.
			on_done(items, nil)
		end)
	end

	local function edit_comment(issue, comment, content, on_done)
		return comments.edit(issue, comment.id, content, function(updated, err)
			if err then
				on_done(nil, err)
				return
			end
			updated.reactions = comment.reactions
			on_done(updated, nil)
		end)
	end

	local function views()
		local cfg = require("atlas.config").domain_options(provider_id, "issues") or {}
		local configured = cfg.views or {}
		if #configured == 0 then
			configured = {
				{ name = "Assigned", key = "1", scope = "assigned", state = "open" },
				{ name = "Created", key = "2", scope = "created", state = "open" },
			}
		end
		return vim.tbl_map(function(view)
			return vim.tbl_extend("force", {}, view)
		end, configured)
	end

	return {
		views = views,
		view_for_target = function(target)
			return { name = "Search", layout = "compact", repo = target.repo_full_name, state = "all" }
		end,
		issue_ref = function(target)
			if target.repo_full_name and target.number then
				return { key = string.format("%s#%d", target.repo_full_name, target.number) }
			end
		end,
		capabilities = {
			actions = require("atlas.issues.providers.forge.actions.registry").new(provider_id, issues),
			core = {
				fetch_issues = fetch_issues,
				fetch_by_refs = issues.fetch_by_refs,
				fetch_issue = issues.get,
			},
			comments = {
				fetch_conversation = fetch_conversation,
				add_comment = comments.add,
				edit_comment = edit_comment,
				delete_comment = function(issue, comment, on_done)
					return comments.delete(issue, comment.id, on_done)
				end,
				reactions = {
					options = require("atlas.providers.forge.mapping").reactions,
					add = function(issue, comment, key, on_done)
						return comments.add_reaction(issue, comment.id, key, on_done)
					end,
				},
			},
			ui = {
				detail = require("atlas.issues.providers.forge.ui.detail"),
				repository = require("atlas.providers.forge.ui.repository"),
			},
		},
	}
end

return M
