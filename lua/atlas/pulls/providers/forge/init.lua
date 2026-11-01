local config = require("atlas.config")
local git = require("atlas.core.git")
local query = require("atlas.pulls.providers.forge.query")
local request_scope = require("atlas.core.requests")

local M = {}

---@param service ForgeService
---@param api table
---@param comments_api table
---@param reviews_api table
---@param pipelines PullsPipelineBackend
---@return PullsProvider
function M.new(service, api, comments_api, reviews_api, pipelines)
	local provider_id = service.id
	local pullrequests_api = api.pullrequests

	local function views()
		local configured = (config.domain_options(provider_id, "pulls") or {}).views
		if not configured or #configured == 0 then
			configured = { { name = "Pull Requests", key = "1", layout = "compact" } }
		end
		return vim.tbl_map(function(view)
			return vim.tbl_extend("force", {}, view)
		end, configured)
	end

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

	local function fetch_pullrequests(view, opts, on_done)
		local requests = request_scope.new()
		requests.run(function(done)
			return resolve_view(view, done)
		end, function(resolved)
			local api_view, statuses = query.for_api(resolved)
			local fetch = vim.trim(api_view.repo or "") == "" and pullrequests_api.search_global
				or pullrequests_api.list
			requests.run(function(done)
				return fetch(api_view, statuses, opts, done)
			end, function(page, err)
				page = page or { items = {} }
				page.query = query.resolve(resolved)
				on_done(page, err and { err } or nil)
			end)
		end)
		return requests
	end

	---@param pr PullRequest
	---@param opts { force_refresh: boolean|nil }|nil
	---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	local function fetch_conversation(pr, opts, on_done)
		return comments_api.fetch(pr, opts, function(result, err)
			if err then
				on_done(nil, err)
				return
			end

			local ordered = {}
			local sequence = 0
			local function add(kind, created_at, entity, id)
				sequence = sequence + 1
				table.insert(ordered, {
					sequence = sequence,
					item = {
						id = id,
						kind = kind,
						created_at = created_at,
						entity = entity,
					},
				})
			end

			for _, comment in ipairs(result.comments) do
				add("comment", comment.created_at, comment, "comment:" .. tostring(comment.id))
			end
			for index, event in ipairs(result.events) do
				local created_at = event.date
				local id = table.concat({ "activity", created_at, event.kind, tostring(index) }, ":")
				add("activity", created_at, event, id)
			end

			table.sort(ordered, function(left, right)
				if left.item.created_at == right.item.created_at then
					return left.sequence < right.sequence
				end
				return left.item.created_at < right.item.created_at
			end)

			local items = {}
			for _, value in ipairs(ordered) do
				table.insert(items, value.item)
			end
			on_done(items, nil)
		end)
	end

	return {
		views = views,
		resolve_search = query.resolve,
		view_for_target = function(target)
			return { name = "Search", layout = "compact", repo = target.repo_full_name }
		end,
		capabilities = {
			actions = require("atlas.pulls.providers.forge.actions.registry").new(service, pullrequests_api),
			core = {
				fetch_pullrequests = fetch_pullrequests,
				fetch_by_refs = pullrequests_api.fetch_by_refs,
				fetch_pullrequest = pullrequests_api.get,
				merge = pullrequests_api.merge,
				decline = pullrequests_api.decline,
				fetch_description = pullrequests_api.description,
				fetch_reviewers = pullrequests_api.reviewers,
				fetch_diffstat = api.files.diffstat,
				fetch_commits = api.commits.fetch,
				fetch_merge_checks = api.checks.fetch,
			},
			write = {
				create = pullrequests_api.create,
				update = pullrequests_api.update_pr,
				fetch_reviewer_candidates = pullrequests_api.fetch_reviewer_candidates,
				fetch_labels = pullrequests_api.list_labels,
				fetch_assignees = function(repo_slug, on_done)
					return service.users.get_assignable_users(repo_slug, nil, on_done)
				end,
			},
			comments = {
				fetch_conversation = fetch_conversation,
				add_comment = comments_api.add,
				edit_comment = comments_api.edit,
				delete_comment = comments_api.delete,
				reactions = {
					options = require("atlas.providers.forge.mapping").reactions,
					add = comments_api.add_reaction,
				},
				set_thread_resolved = comments_api.set_thread_resolved,
			},
			reviews = {
				fetch = reviews_api.fetch,
				fetch_threads = reviews_api.fetch,
				start_review = reviews_api.start_review,
				submit_review = reviews_api.submit_review,
				approve = reviews_api.approve,
				request_changes = reviews_api.request_changes,
				discard_review = reviews_api.discard_review,
			},
			pipelines = pipelines,
			ui = {
				detail = require("atlas.pulls.providers.forge.ui.detail"),
				repository = require("atlas.providers.forge.ui.repository"),
			},
		},
	}
end

return M
