local module_name = "atlas.pulls.providers.gitlab.api.comments"
local client_name = "atlas.providers.gitlab.client"
local reactions_name = "atlas.providers.gitlab.reactions"

describe("GitLab merge request comments", function()
	local api, notes, cached, previous
	local pr = { id = 12, repo_full_name = "group/project", author = { username = "alice" } }

	before_each(function()
		previous = {}
		for _, name in ipairs({ module_name, client_name, reactions_name }) do
			previous[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		notes = {}
		cached = nil
		package.loaded[client_name] = {
			graphql = function(_, _, callback)
				callback({
					currentUser = { username = "alice" },
					project = {
						mergeRequest = {
							id = "gid://gitlab/MergeRequest/12",
							description = "Description",
							notes = { nodes = notes, pageInfo = { hasNextPage = false } },
						},
					},
				}, nil)
			end,
			fetch_all_pages = function(_, callback)
				callback({}, nil)
			end,
			url_encode = function(value)
				return (value:gsub("/", "%%2F"))
			end,
			set_memory_cache = function(_, value)
				cached = value
			end,
		}
		api = require(module_name)
	end)

	after_each(function()
		for _, name in ipairs({ module_name, client_name, reactions_name }) do
			package.loaded[name] = previous[name]
		end
	end)

	for _, method in ipairs({ "fetch_review_threads", "fetch_conversation_comments" }) do
		describe(method, function()
			local function fetch()
				local result, err
				api[method](pr, { force_refresh = true }, function(value, error_message)
					result, err = value, error_message
				end)
				assert.is_nil(err)
				assert.is_table(result)
				assert.same(result, cached)
				return method == "fetch_conversation_comments" and result.comments or result
			end

			it("preserves comments with missing or null discussion data", function()
				for _, case in ipairs({
					{},
					{ discussion = vim.NIL },
					{ discussion = {} },
					{ discussion = { id = vim.NIL } },
				}) do
					notes = {
						{
							id = "gid://gitlab/Note/1",
							body = "Standalone comment",
							discussion = case.discussion,
						},
					}

					local comments = fetch()
					assert.equal(1, #comments)
					assert.equal("Standalone comment", comments[1].body)
					assert.is_nil(comments[1].thread_id)
					assert.is_nil(comments[1].parent_id)
					assert.is_nil(comments[1].hunk)
				end
			end)

			it("preserves normal thread relationships and resolved context", function()
				local discussion = {
					id = "gid://gitlab/Discussion/d1",
					resolved = true,
					notes = { nodes = { { id = "gid://gitlab/Note/1" } } },
					truncatedDiffLines = { { type = "new", newLine = 1, text = "+line" } },
				}
				notes = {
					{ id = "gid://gitlab/Note/1", body = "Root", discussion = discussion },
					{
						id = "gid://gitlab/Note/2",
						body = "Reply",
						discussion = {
							id = discussion.id,
							notes = discussion.notes,
						},
					},
				}

				local comments = fetch()
				assert.equal(2, #comments)
				assert.equal(discussion.id, comments[1].thread_id)
				assert.is_nil(comments[1].parent_id)
				assert.equal(comments[1].id, comments[2].parent_id)
				assert.equal(discussion.id, comments[2].thread_id)
				assert.equal("RESOLVED", comments[2].state)
				if method == "fetch_review_threads" then
					assert.equal("line", comments[1].hunk.lines[1].content)
				end
			end)
		end)
	end
end)
