local github_client = require("spec.support.github_client_stub")

local MODULE = "atlas.providers.github.links"

local function subject(kind, slug, number)
	return {
		__typename = kind == "pr" and "PullRequest" or "Issue",
		number = number,
		title = "Linked " .. kind .. " " .. number,
		url = "https://github.com/" .. slug .. (kind == "pr" and "/pull/" or "/issues/") .. number,
		repository = { nameWithOwner = slug },
	}
end

local function response(fields)
	local item = {
		url = "https://github.com/octo/repo/issues/1",
		subIssues = { nodes = {} },
		closedByPullRequestsReferences = { nodes = {} },
		blockedBy = { nodes = {} },
		blocking = { nodes = {} },
		closingIssuesReferences = { nodes = {} },
		timelineItems = { nodes = {} },
	}
	for field, value in pairs(fields or {}) do
		item[field] = value
	end
	return {
		data = {
			repository = {
				item = item,
			},
		},
	}
end

describe("GitHub related issues and pull requests", function()
	local handler

	before_each(function()
		github_client.install({
			gh = function(args, callback, context)
				local call = { args = args, callback = callback, context = context }
				if handler then
					return handler(call)
				end
				callback(response(), nil)
			end,
		})
		local client = require("atlas.providers.github.client")
		client.get_mem = function() end
		client.set_mem = function() end
		package.loaded[MODULE] = nil
	end)

	after_each(function()
		handler = nil
		github_client.uninstall()
		package.loaded[MODULE] = nil
	end)

	it("fetches all issue relationships and keeps repository-qualified identities", function()
		local parent = subject("issue", "other/project", 1)
		local pr = subject("pr", "other/project", 10)
		handler = function(call)
			assert.matches("includeClosedPrs: true", table.concat(call.args, " "), 1, true)
			call.callback(response({
				parent = parent,
				subIssues = { nodes = { subject("issue", "octo/repo", 3) } },
				closedByPullRequestsReferences = { nodes = { pr } },
				blockedBy = { nodes = { subject("issue", "octo/repo", 4) } },
				blocking = { nodes = { subject("issue", "octo/repo", 4) } },
				timelineItems = { nodes = { { source = pr }, { source = subject("issue", "elsewhere/repo", 8) } } },
			}))
		end
		local links, err
		require(MODULE).fetch_issue({ key = "octo/repo#1" }, nil, function(result, error)
			links, err = result, error
		end)
		assert.is_nil(err)
		assert.equal(6, #links)
		assert.equal("other/project#1", links[1].key)
		assert.equal("parent", links[1].relationship)
		assert.equal("sub-issue", links[2].relationship)
		assert.equal("pr", links[3].kind)
		assert.equal("closed by", links[3].relationship)
		assert.equal("blocked by", links[4].relationship)
		assert.equal("blocks", links[5].relationship)
		assert.equal("referenced by", links[6].relationship)
	end)

	it("deduplicates referenced issues and preserves native closing relationships", function()
		handler = function(call)
			local event = { source = subject("issue", "other/repo", 3) }
			call.callback(response({
				url = "https://github.com/octo/repo/pull/10",
				closingIssuesReferences = {
					nodes = { subject("issue", "other/repo", 1), subject("issue", "other/repo", 2) },
				},
				timelineItems = { nodes = { { source = subject("issue", "other/repo", 2) }, event, event } },
			}))
		end
		local links
		require(MODULE).fetch_pr({ repo_full_name = "octo/repo", id = "10" }, nil, function(result, err)
			assert.is_nil(err)
			links = result
		end)
		assert.equal(3, #links)
		assert.equal("other/repo#1", links[1].key)
		assert.equal("other/repo#2", links[2].key)
		assert.equal("closes", links[2].relationship)
		assert.equal("other/repo#3", links[3].key)
		assert.equal("referenced by", links[3].relationship)
	end)
end)
