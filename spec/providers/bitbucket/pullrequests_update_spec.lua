local function fresh_module()
	package.loaded["atlas.pulls.providers.bitbucket.api.pullrequests"] = nil
	return require("atlas.pulls.providers.bitbucket.api.pullrequests")
end

local function stub_service(request)
	package.preload["atlas.providers.bitbucket.client"] = function()
		return {
			request = request,
			clear_cache = function() end,
		}
	end
end

describe("bitbucket pull request updates", function()
	local calls

	before_each(function()
		calls = {}
		package.loaded["atlas.providers.bitbucket.client"] = nil
	end)

	after_each(function()
		package.preload["atlas.providers.bitbucket.client"] = nil
		package.loaded["atlas.providers.bitbucket.client"] = nil
		package.loaded["atlas.pulls.providers.bitbucket.api.pullrequests"] = nil
	end)

	it("combines the merge title and body", function()
		stub_service(function(_, _, _, body, callback)
			table.insert(calls, body)
			callback({}, nil)
		end)
		local api = fresh_module()
		local pr = {
			id = 5,
			links = { merge = "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/5/merge" },
		}
		for index, case in ipairs({
			{ method = "merge", body = "Body", message = "Subject\n\nBody" },
			{ method = "squash", body = "", message = "Subject" },
		}) do
			api.merge(pr, {
				method = case.method,
				delete_source_branch = true,
				subject = "Subject",
				body = case.body,
			}, function() end)
			assert.equal(
				vim.json.encode({
					close_source_branch = true,
					merge_strategy = case.method == "merge" and "merge_commit" or "squash",
					message = case.message,
				}),
				calls[index]
			)
		end
	end)

	it("preserves explicit empty selections and false draft", function()
		stub_service(function(_, _, _, body, callback)
			table.insert(calls, body)
			callback({}, nil)
		end)
		local api = fresh_module()
		local pr = { id = 5, links = { self = "url" } }

		api.update_pr(pr, { body = "", draft = false, reviewers = {} }, function(ok, err)
			assert.is_true(ok)
			assert.is_nil(err)
		end)
		api.update_pr(pr, { title = "New title" }, function() end)

		assert.same({
			vim.json.encode({ description = "", draft = false, reviewers = {} }),
			vim.json.encode({ title = "New title" }),
		}, calls)
	end)
end)
