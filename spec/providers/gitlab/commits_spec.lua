local module_name = "atlas.pulls.providers.gitlab.api.changes"

local function fresh_module()
	package.loaded[module_name] = nil
	return require(module_name)
end

---@param fetch_all_pages fun(endpoint: string, callback: function, ctx: table|nil)
local function stub_service(fetch_all_pages)
	rawset(package.preload, "atlas.providers.gitlab.client", function()
		return {
			fetch_all_pages = fetch_all_pages,
			url_encode = function(value)
				return (tostring(value):gsub("/", "%%2F"))
			end,
			get_memory_cache = function()
				return nil, false
			end,
			set_memory_cache = function() end,
		}
	end)
end

describe("gitlab pulls.fetch_commits", function()
	before_each(function()
		package.loaded[module_name] = nil
		package.loaded["atlas.providers.gitlab.client"] = nil
	end)

	after_each(function()
		package.preload["atlas.providers.gitlab.client"] = nil
		package.loaded["atlas.providers.gitlab.client"] = nil
		package.loaded[module_name] = nil
	end)

	it("fails fast when the MR identifier is invalid", function()
		local calls = 0
		stub_service(function()
			calls = calls + 1
		end)
		local api = fresh_module()

		local commits, err
		api.fetch_commits({ id = nil, repo_full_name = "group/project" }, nil, function(c, e)
			commits, err = c, e
		end)

		assert.is_nil(commits)
		assert.equal("Invalid MR identifier", err)
		assert.equal(0, calls)
	end)

	it("keeps full commit messages and falls back to the title when absent", function()
		stub_service(function(endpoint, callback)
			assert.equal("/projects/group%2Fproject/merge_requests/12/commits", endpoint)
			callback({
				{
					id = "abc123def456",
					short_id = "abc123d",
					title = "Fix bug",
					message = "Fix bug\n\nThis explains why the fix is needed.\nSecond body line.",
					author_name = "Alice",
					authored_date = "2024-01-02T03:04:05Z",
				},
				{ id = "def456", title = "Title only" },
			}, nil)
		end)
		local api = fresh_module()

		local commits
		api.fetch_commits({ id = 12, repo_full_name = "group/project" }, nil, function(c)
			commits = c
		end)

		assert.equal(2, #commits)
		assert.equal("Fix bug\n\nThis explains why the fix is needed.\nSecond body line.", commits[1].message)
		assert.equal("abc123def456", commits[1].hash)
		assert.equal("abc123d", commits[1].short_hash)
		assert.equal("Title only", commits[2].message)
	end)

	it("propagates errors from the request", function()
		stub_service(function(_, callback)
			callback(nil, "boom")
		end)
		local api = fresh_module()

		local commits, err
		api.fetch_commits({ id = 12, repo_full_name = "group/project" }, nil, function(c, e)
			commits, err = c, e
		end)

		assert.is_nil(commits)
		assert.equal("boom", err)
	end)
end)
