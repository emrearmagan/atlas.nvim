local github_client = require("spec.support.github_client_stub")

local MODULE = "atlas.providers.github.discussions"

local function fetch(repository, search)
	local sent
	github_client.install({
		gh = function(args, callback)
			sent = args
			callback({ data = { repository = repository, search = search } }, nil)
		end,
	})
	package.loaded[MODULE] = nil
	local page, err
	require(MODULE).fetch({ full_name = "octo/repo" }, { query = "repo:octo/repo is:open" }, function(value, fetch_err)
		page, err = value, fetch_err
	end)
	return page, err, sent
end

local function fetch_discussion(repository)
	github_client.install({
		gh = function(_, callback)
			callback({ data = { repository = repository } }, nil)
		end,
	})
	package.loaded[MODULE] = nil
	local discussion, err
	require(MODULE).fetch_discussion({ full_name = "octo/repo" }, 43, function(value, fetch_err)
		discussion, err = value, fetch_err
	end)
	return discussion, err
end

describe("GitHub discussions", function()
	after_each(function()
		github_client.uninstall()
		package.loaded[MODULE] = nil
	end)

	it("maps searched discussions and marks pinned ones", function()
		local page, _, sent = fetch({
			hasDiscussionsEnabled = true,
			discussionCategories = {
				nodes = { { id = "C1", name = "Announcements", emoji = ":mega:", isAnswerable = false } },
			},
			pinnedDiscussions = { nodes = { { discussion = { number = 40 } } } },
		}, {
			pageInfo = { hasNextPage = true, endCursor = "next" },
			nodes = {
				{
					number = 40,
					title = "Welcome",
					url = "https://github.com/octo/repo/discussions/40",
					createdAt = "2026-07-13T17:41:27Z",
					isAnswered = vim.NIL,
					upvoteCount = 1,
					author = { login = "octo" },
					category = { id = "C1", name = "Announcements", emoji = ":mega:", isAnswerable = false },
					labels = { nodes = { { name = "news", color = "0e8a16" } } },
					comments = { totalCount = 3 },
				},
				{
					number = 43,
					title = "PR Reviews",
					isAnswered = true,
					author = vim.NIL,
					category = { name = "Q&A", emoji = ":pray:", isAnswerable = true },
					labels = { nodes = {} },
					comments = { totalCount = 1 },
				},
			},
		})

		page = assert(page)
		assert.are.same({ "-f", "search=repo:octo/repo is:open" }, { sent[#sent - 1], sent[#sent] })
		assert.are.same({ { id = "C1", name = "Announcements", emoji = "mega", answerable = false } }, page.categories)
		assert.are.equal("next", page.next_cursor)
		assert.are.same({
			number = 40,
			title = "Welcome",
			url = "https://github.com/octo/repo/discussions/40",
			author = "octo",
			category = { id = "C1", name = "Announcements", emoji = "mega", answerable = false },
			labels = { { name = "news", color = "0e8a16" } },
			comments = 3,
			upvotes = 1,
			answered = false,
			closed = false,
			pinned = true,
			created_at = "2026-07-13T17:41:27Z",
		}, page.items[1])
		assert.is_true(page.items[2].answered)
		assert.is_false(page.items[2].pinned)
		assert.is_nil(page.items[2].author)
	end)

	it("maps a discussion with its thread and nested replies", function()
		local discussion = assert(fetch_discussion({
			discussion = {
				id = "D_1",
				number = 43,
				title = "How?",
				body = "Question",
				viewerSubscription = "SUBSCRIBED",
				category = { id = "C1", name = "Q&A", emoji = ":pray:", isAnswerable = true },
				reactionGroups = { { content = "THUMBS_UP", viewerHasReacted = true, reactors = { totalCount = 2 } } },
				comments = {
					totalCount = 3,
					nodes = {
						{
							body = "Answer",
							createdAt = "2026-08-01T10:00:00Z",
							isAnswer = true,
							upvoteCount = 1,
							viewerHasUpvoted = true,
							author = { login = "octo" },
							reactionGroups = {},
							replies = {
								nodes = {
									{
										body = "Thanks",
										createdAt = "2026-08-02T10:00:00Z",
										upvoteCount = 0,
										author = vim.NIL,
										reactionGroups = {},
									},
								},
							},
						},
						{
							body = "",
							createdAt = "2026-08-03T10:00:00Z",
							deletedAt = "2026-08-04T10:00:00Z",
							author = { login = "octo" },
							reactionGroups = {},
						},
					},
				},
			},
		}))

		assert.are.equal("D_1", discussion.description.id)
		assert.are.equal("How?", discussion.title)
		assert.are.equal("Q&A", discussion.category.name)
		assert.are.equal(3, discussion.comments)
		assert.are.equal("Question", discussion.description.body)
		assert.is_true(discussion.subscribed)
		assert.are.equal("thumbsup", discussion.description.reactions[1].name)
		assert.are.equal(2, discussion.description.reactions[1].count)
		assert.is_true(discussion.description.reactions[1].reacted)
		assert.is_true(discussion.thread[1].answer)
		assert.is_true(discussion.thread[1].upvoted)
		assert.is_false(discussion.thread[1].deleted)
		assert.is_true(discussion.thread[2].deleted)
		assert.is_false(discussion.thread[1].replies[1].upvoted)
		assert.are.equal("octo", discussion.thread[1].author)
		assert.are.equal("Thanks", discussion.thread[1].replies[1].body)
		assert.is_nil(discussion.thread[1].replies[1].author)
		assert.is_false(discussion.thread[1].replies[1].answer)
	end)

	it("replies to a top-level comment and maps the created comment", function()
		local sent
		github_client.install({
			gh = function(args, callback)
				sent = args
				callback({
					data = {
						addDiscussionComment = {
							comment = {
								id = "DC_2",
								body = "Thanks",
								createdAt = "2026-10-16T10:00:00Z",
								upvoteCount = 0,
								author = { login = "octo" },
								reactionGroups = {},
							},
						},
					},
				}, nil)
			end,
		})
		package.loaded[MODULE] = nil
		local created
		require(MODULE).add_comment(
			{ number = 43, description = { id = "D_1" } },
			"Thanks",
			{ id = "DC_1" },
			function(comment)
				created = comment
			end
		)

		assert.are.same({ "-f", "replyToId=DC_1" }, { sent[#sent - 1], sent[#sent] })
		assert.are.equal("DC_2", created.id)
		assert.are.equal("octo", created.author)
		assert.are.same({}, created.replies)
	end)

	it("edits the description through the discussion and comments through the comment", function()
		local queries = {}
		github_client.install({
			gh = function(args, callback)
				table.insert(queries, args[4])
				callback({}, nil)
			end,
		})
		package.loaded[MODULE] = nil
		local description, comment = { id = "D_1" }, { id = "DC_1" }
		local discussion = { description = description }
		require(MODULE).edit_comment(discussion, description, "Body", function() end)
		require(MODULE).edit_comment(discussion, comment, "Body", function() end)

		assert.truthy(queries[1]:find("updateDiscussion(", 1, true))
		assert.truthy(queries[2]:find("updateDiscussionComment(", 1, true))
	end)
end)
