local config = require("atlas.config")
local mapper = require("atlas.pulls.providers.forge.api.mapper").new("gitea")
local pull_requests = require("atlas.pulls.providers.forge.api.pullrequests")
local TRANSPORT = "atlas.providers.forge.gitea.api"
local PREFIX = "atlas.pulls.providers.forge.gitea"

local function cleanup()
	package.loaded[TRANSPORT], package.preload[TRANSPORT] = nil, nil
	for module in pairs(package.loaded) do
		if module:sub(1, #PREFIX) == PREFIX then
			package.loaded[module] = nil
		end
	end
end

describe("Gitea", function()
	local old_config
	before_each(function()
		cleanup()
		old_config = config.domain_options
		config.domain_options = function()
			return { draft_prefix = "Draft:" }
		end
	end)
	after_each(function()
		config.domain_options = old_config
		cleanup()
	end)

	it("expands closed searches into merged and declined while preserving literal text", function()
		local query = require("atlas.pulls.providers.forge.query")
		local view = {}
		assert.is_true(query.apply(view, 'repo:owner/repo is:closed search:"is:open literal"'))
		local parsed, states = query.for_api(view)
		assert.same({ "MERGED", "DECLINED" }, states)
		assert.equal("owner/repo", parsed.repo)
		assert.equal("is:open literal", parsed.search)
		local previous = vim.deepcopy(view)
		assert.is_false(query.apply(view, "is:unknown"))
		assert.same(previous, view)
	end)

	it("keeps the view scope in the editable query", function()
		local query = require("atlas.pulls.providers.forge.query")
		local view = { scope = "created" }
		assert.equal("type:pulls is:open scope:created", (query.resolve(view)))
		assert.is_true(query.apply(view, "type:pulls is:open scope:review_requested"))
		assert.equal("review_requested", query.for_api(view).scope)
		assert.is_false(query.apply(view, "scope:unknown"))
	end)

	it("searches a scoped repository view by owner and keeps only that repository", function()
		local endpoint, params
		local service = {
			id = "gitea",
			name = "Gitea",
			url_encode = tostring,
			base_url = function()
				return "https://forge.example"
			end,
			query = function(values)
				params = values
				return ""
			end,
			get_cache = function()
				return nil, false
			end,
			set_cache = function() end,
			request = function(_, path, _, done)
				endpoint = path
				local user = { id = 1, login = "alice" }
				done({
					{
						number = 1,
						state = "open",
						user = user,
						pull_request = {},
						repository = { full_name = "Owner/Repo" },
					},
					{
						number = 2,
						state = "open",
						user = user,
						pull_request = {},
						repository = { full_name = "owner/other" },
					},
				}, nil)
			end,
		}
		local result
		pull_requests
			.new(service, mapper)
			.list({ repo = "owner/repo", scope = "review_requested" }, { "OPEN" }, {}, function(page, err)
				assert.is_nil(err)
				result = page.items
			end)
		assert.equal("/repos/issues/search", endpoint)
		assert.is_true(params.review_requested)
		assert.equal("owner", params.owner)
		assert.same(
			{ "1" },
			vim.tbl_map(function(pr)
				return tostring(pr.id)
			end, result)
		)
	end)

	it("groups comments by review position and keeps pending state separate from resolution", function()
		local service = {
			id = "gitea",
			name = "Gitea",
			url_encode = tostring,
			notifications = {},
			fetch_all = function(_, _, _, done)
				done({
					{ id = 10, state = "COMMENT", comments_count = 3, stale = true },
					{ id = 12, state = "PENDING", comments_count = 1 },
				}, nil)
			end,
			request = function(_, endpoint, _, done)
				if endpoint:match("/10/comments$") then
					done({
						{ id = 102, path = "main.lua", position = 7 },
						{ id = 103, path = "main.lua", position = 9 },
						{ id = 101, path = "main.lua", position = 7 },
					}, nil)
				else
					done({
						{ id = 121, path = "main.lua", original_position = 4, resolver = { id = 1, login = "alice" } },
					}, nil)
				end
			end,
		}
		package.preload[TRANSPORT] = function()
			return service
		end
		local result
		require(PREFIX .. ".api.reviews").fetch(
			{ id = 3, repo_full_name = "owner/repo", source = { commit_hash = "head" } },
			nil,
			function(value, err)
				assert.is_nil(err)
				result = value.comments
			end
		)
		assert.same(
			{ 101, 102, 103, 121 },
			vim.tbl_map(function(comment)
				return comment.id
			end, result)
		)
		assert.equal(101, result[2].parent_id)
		assert.is_nil(result[3].parent_id)
		assert.equal("OUTDATED", result[1].state)
		assert.is_true(result[4].pending)
		assert.equal("RESOLVED", result[4].state)
		assert.equal(4, result[4].inline.from)
	end)

	it("rejects multiline comments without posting a partial comment", function()
		package.preload[TRANSPORT] = function()
			return {
				id = "gitea",
				name = "Gitea",
				url_encode = tostring,
				request = function()
					error("A rejected range must not be submitted")
				end,
			}
		end
		require(PREFIX .. ".api.reviews").add(
			{ id = 3, repo_full_name = "owner/repo", source = { commit_hash = "head" } },
			"Range",
			{ path = "main.lua", start_to = 2, to = 4 },
			nil,
			function(comment, err)
				assert.is_nil(comment)
				assert.equal("Gitea does not support multi-line review comments", err)
			end
		)
	end)

	local function editing_api(accept_draft)
		local raw = {
			number = 3,
			title = "Draft: Original",
			draft = true,
			state = "open",
			user = { id = 1, login = "author" },
			head = { ref = "feature", sha = "head", repo = { full_name = "owner/repo" } },
			base = { ref = "main", sha = "base", repo = { full_name = "owner/repo" } },
		}
		local writes = {}
		local service = {
			id = "gitea",
			name = "Gitea",
			url_encode = tostring,
			base_url = function()
				return "https://forge.example"
			end,
			clear_cache = function() end,
			delete_memory_cache = function() end,
			fetch_all = function(_, _, _, done)
				done({
					{ id = 1, state = "REQUEST_REVIEW", user = { id = 2, login = "keep" } },
					{ id = 2, state = "REQUEST_REVIEW", user = { id = 3, login = "remove" } },
				}, nil)
			end,
			request = function(method, _, data, done)
				writes[#writes + 1] = { method = method, data = data }
				if method == "PATCH" then
					for key, value in pairs(data) do
						raw[key] = value
					end
					raw.draft = accept_draft and raw.title:sub(1, 6) == "Draft:"
				end
				done(vim.deepcopy(raw), nil)
			end,
		}
		return pull_requests.new(service, mapper), mapper.to_pull_request(raw), writes
	end

	local function saved(ok, err)
		assert.is_nil(err)
		assert.is_true(ok)
	end

	it("preserves the configured draft prefix on rename and removes it when ready", function()
		local api, pr = editing_api(true)
		api.update_pr(pr, { title = "Renamed" }, saved)
		assert.equal("Draft: Renamed", pr.title)
		assert.equal("draft", pr.state)
		api.update_pr(pr, { draft = false }, saved)
		assert.equal("Renamed", pr.title)
		assert.equal("open", pr.state)
	end)

	it("restores the title without changing the body when the server rejects draft state", function()
		local api, pr, writes = editing_api(false)
		pr.title, pr.state = "Original", "open"
		api.update_pr(pr, { draft = true, body = "Must not change" }, function(ok, err)
			assert.is_false(ok)
			assert.matches("configure an enabled draft_prefix", err, 1, true)
		end)
		assert.equal("Original", pr.title)
		assert.same({
			{ method = "PATCH", data = { title = "Draft: Original" } },
			{ method = "PATCH", data = { title = "Original" } },
		}, writes)
	end)

	it("updates only changed reviewers and deduplicates the selection", function()
		local api, pr, writes = editing_api(true)
		api.update_pr(pr, {
			reviewers = { { provider_id = "keep" }, { provider_id = "new" }, { provider_id = "new" } },
		}, saved)
		assert.same({
			{ method = "POST", data = { reviewers = { "new" }, team_reviewers = {} } },
			{ method = "DELETE", data = { reviewers = { "remove" }, team_reviewers = {} } },
		}, writes)
	end)
end)
