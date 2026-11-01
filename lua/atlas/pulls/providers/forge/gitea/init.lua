---@class GiteaPullRequest : PullRequest
---@field lines_added number|nil
---@field lines_removed number|nil
---@field mergeable boolean|nil
---@field merge_base string|nil

---@class GiteaPullRequestDetails : PullRequestDetails
---@field assignees AtlasUser[]
---@field labels PullsLabel[]

local api = require("atlas.pulls.providers.forge.gitea.api")
local comments_api = require("atlas.pulls.providers.forge.gitea.api.comments")
local forge = require("atlas.pulls.providers.forge")
local mapping = require("atlas.providers.forge.mapping")
local query = require("atlas.pulls.providers.forge.query")
local reviews_api = require("atlas.pulls.providers.forge.gitea.api.reviews")
local service = require("atlas.providers.forge.gitea.api")

require("atlas.pulls.providers.forge.gitea.config")

local pullrequests_api = api.pullrequests

return {
	views = function()
		return forge.views("gitea")
	end,
	repository_view = forge.repository_view,
	resolve_search = query.resolve,
	capabilities = {
		actions = require("atlas.pulls.providers.forge.actions.registry").new(service, pullrequests_api),
		core = {
			fetch_pullrequests = function(view, opts, on_done)
				return forge.fetch_pullrequests("gitea", pullrequests_api, view, opts, on_done)
			end,
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
			fetch_conversation = comments_api.fetch,
			add_comment = comments_api.add,
			edit_comment = comments_api.edit,
			delete_comment = comments_api.delete,
			reactions = {
				options = mapping.reactions,
				add = comments_api.add_reaction,
			},
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			fetch_threads = reviews_api.fetch,
			submit_review = reviews_api.submit_review,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard_review,
		},
		pipelines = require("atlas.pulls.pipelines.forge.gitea"),
		ui = {
			detail = require("atlas.pulls.providers.forge.ui.detail"),
			repository = require("atlas.providers.forge.ui.repository"),
		},
	},
}
