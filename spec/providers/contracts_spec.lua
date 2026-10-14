local providers = require("atlas.providers")

local function assert_functions(value, names, label)
	assert.equal("table", type(value), label)
	for _, name in ipairs(names) do
		assert.equal("function", type(value[name]), label .. "." .. name)
	end
end

local function assert_contract(domain, expected_ids, provider_functions, core_functions)
	local ids = {}
	for _, registered in ipairs(providers.list(domain)) do
		ids[#ids + 1] = registered.id
		local provider = assert(providers.load(registered.id, domain))
		local label = registered.id .. "." .. domain

		assert.equal(registered.id, provider.id)
		assert.equal(registered.name, provider.name)
		assert_functions(provider, provider_functions, label)
		assert_functions(provider.capabilities and provider.capabilities.core, core_functions, label .. ".core")
		assert_functions(provider.capabilities.users, { "fetch_user" }, label .. ".users")
		if domain == "pulls" then
			assert_functions(
				provider.capabilities.write,
				{ "create", "update", "fetch_reviewer_candidates" },
				label .. ".write"
			)
			for _, name in ipairs({ "create_pr", "set_draft", "update_reviewers", "fetch_reviewer_candidates" }) do
				assert.equal(nil, provider.capabilities.core[name], label .. ".core." .. name)
			end
			local pipelines = assert(provider.capabilities and provider.capabilities.pipelines)
			assert_functions(pipelines, { "fetch" }, label .. ".pipelines")
			assert.equal("table", type(pipelines.actions), label .. ".pipelines.actions")
		end
	end
	table.sort(ids)
	assert.same(expected_ids, ids)
end

describe("providers contracts", function()
	it("loads pull request providers", function()
		assert_contract(
			"pulls",
			{ "bitbucket", "github", "gitlab" },
			{ "resolve_search", "view_for_target", "views" },
			{
				"fetch_pullrequests",
				"fetch_by_refs",
				"fetch_pullrequest",
				"decline",
				"fetch_reviewers",
				"fetch_description",
			}
		)
	end)

	it("exposes editable labels and assignees for GitHub and GitLab", function()
		for _, id in ipairs({ "github", "gitlab" }) do
			local provider = assert(providers.load(id, "pulls"))
			assert_functions(provider.capabilities.write, { "fetch_labels", "fetch_assignees" }, id .. ".pulls.write")
		end
		local bitbucket = assert(providers.load("bitbucket", "pulls"))
		assert.is_nil(bitbucket.capabilities.write.fetch_labels)
		assert.is_nil(bitbucket.capabilities.write.fetch_assignees)
	end)

	it("loads issue providers", function()
		assert_contract(
			"issues",
			{ "github", "gitlab", "jira", "shortcut" },
			{ "view_for_target", "issue_ref", "views" },
			{ "fetch_issues", "fetch_by_refs", "fetch_issue" }
		)
	end)

	it("exposes Bitbucket review actions", function()
		local provider = assert(providers.load("bitbucket", "pulls"))
		local reviews = assert(provider.capabilities.reviews)

		assert_functions(reviews, { "fetch", "submit_review", "approve", "request_changes" }, "bitbucket.pulls.reviews")
	end)

	it("exposes notifications for GitHub and GitLab", function()
		for _, id in ipairs({ "github", "gitlab" }) do
			for _, domain in ipairs({ "pulls", "issues" }) do
				local provider = assert(providers.load(id, domain))
				assert_functions(
					provider.capabilities.notifications,
					{ "fetch", "mark_read", "mark_done" },
					id .. "." .. domain .. ".notifications"
				)
			end
		end
	end)

	it("exposes Shortcut comments", function()
		local provider = assert(providers.load("shortcut", "issues"))
		assert_functions(provider.capabilities.comments, {
			"fetch_activity",
			"fetch_conversation",
			"add_comment",
			"edit_comment",
			"delete_comment",
		}, "shortcut.issues.comments")
		assert_functions(provider.capabilities.comments.reactions, { "add" }, "shortcut.issues.comments.reactions")
		assert.is_true(#provider.capabilities.comments.reactions.options > 0)
	end)
end)
