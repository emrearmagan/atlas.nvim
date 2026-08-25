local CLIENT = "atlas.providers.gitea.client"
local PAGINATION = "atlas.providers.gitea.pagination"
local REVIEWS = "atlas.pulls.providers.gitea.api.reviews"
local PREFIX = "atlas.pulls.providers.gitea"

local function cleanup()
	package.loaded[CLIENT] = nil
	package.preload[CLIENT] = nil
	package.loaded[PAGINATION] = nil
	for module in pairs(package.loaded) do
		if module:sub(1, #PREFIX) == PREFIX then
			package.loaded[module] = nil
		end
	end
end

local function pull_request()
	return {
		id = 3,
		repo_full_name = "owner/repo",
		source = { commit_hash = "head" },
		reviewers = {},
	}
end

local function load_reviews(raw_reviews, requests, pending_callbacks)
	package.preload[CLIENT] = function()
		return {
			url_encode = tostring,
			query = function(params)
				assert.equal(1, params.page)
				assert.equal(50, params.limit)
				return "?page=1"
			end,
			request = function(method, endpoint, _, done)
				table.insert(requests, method .. " " .. endpoint)
				if endpoint:match("/reviews%?page=1$") then
					done(raw_reviews, nil)
				else
					pending_callbacks[endpoint] = done
				end
				return { cancel = function() end }
			end,
		}
	end
	return require(REVIEWS)
end

local function raw_reviews()
	return {
		{
			id = 10,
			state = "COMMENT",
			comments_count = 3,
			commit_id = "old",
			stale = true,
			user = { id = 1, login = "published" },
		},
		{
			id = 11,
			state = "APPROVED",
			comments_count = 0,
			commit_id = "head",
			user = { id = 2, login = "without-comments" },
		},
		{
			id = 12,
			state = "PENDING",
			comments_count = 1,
			commit_id = "head",
			user = { id = 3, login = "pending" },
		},
	}
end

describe("Gitea pull review comments", function()
	before_each(cleanup)
	after_each(cleanup)

	it("fetches only comment-bearing reviews and maps comments in review order", function()
		local requests, callbacks = {}, {}
		local reviews = load_reviews(raw_reviews(), requests, callbacks)
		local data, fetch_err
		reviews.fetch(pull_request(), nil, function(value, err)
			data, fetch_err = value, err
		end)

		local published = "/repos/owner/repo/pulls/3/reviews/10/comments"
		local pending = "/repos/owner/repo/pulls/3/reviews/12/comments"
		assert.is_function(callbacks[published])
		assert.is_function(callbacks[pending])
		assert.is_nil(callbacks["/repos/owner/repo/pulls/3/reviews/11/comments"])

		-- Complete them out of order; the result must still follow review order.
		callbacks[pending]({
			{
				id = 121,
				body = "pending comment",
				path = "pending.lua",
				original_position = 4,
				commit_id = "head",
				user = { id = 3, login = "pending" },
			},
		}, nil)
		callbacks[published]({
			{
				id = 102,
				body = "reply",
				path = "published.lua",
				position = 7,
				commit_id = "old",
				user = { id = 1, login = "published" },
			},
			{
				id = 103,
				body = "another thread",
				path = "published.lua",
				position = 9,
				commit_id = "old",
				user = { id = 1, login = "published" },
			},
			{
				id = 101,
				body = "thread root",
				path = "published.lua",
				position = 7,
				commit_id = "old",
				user = { id = 1, login = "published" },
			},
		}, nil)

		assert.is_nil(fetch_err)
		assert.same(
			{ 101, 102, 103, 121 },
			{ data.comments[1].id, data.comments[2].id, data.comments[3].id, data.comments[4].id }
		)
		assert.is_nil(data.comments[1].parent_id)
		assert.equal(101, data.comments[2].parent_id)
		assert.is_nil(data.comments[3].parent_id)
		assert.equal("OUTDATED", data.comments[1].state)
		assert.equal(7, data.comments[1].inline.to)
		assert.equal("PENDING", data.comments[4].state)
		assert.equal(4, data.comments[4].inline.from)
		assert.equal("GET /repos/owner/repo/pulls/3/reviews?page=1", requests[1])
		local comment_requests = { requests[2], requests[3] }
		table.sort(comment_requests)
		assert.same({ "GET " .. published, "GET " .. pending }, comment_requests)
	end)
end)
