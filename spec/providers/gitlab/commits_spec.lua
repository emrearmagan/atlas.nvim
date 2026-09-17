local module_name = "atlas.pulls.providers.gitlab.api.changes"

local function fresh_module()
	package.loaded[module_name] = nil
	return require(module_name)
end

---@param request fun(method: string, endpoint: string, payload: table|nil, callback: function, ctx: table|nil)
local function stub_service(request)
	package.preload["atlas.providers.gitlab.client"] = function()
		return {
			request = request,
			url_encode = function(value)
				return (tostring(value):gsub("/", "%%2F"))
			end,
			get_memory_cache = function()
				return nil, false
			end,
			set_memory_cache = function() end,
		}
	end
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

	it("keeps the full multi-line commit message instead of just the title", function()
		stub_service(function(_, _, _, callback)
			callback({
				{
					id = "abc123def456",
					short_id = "abc123d",
					title = "Fix bug",
					message = "Fix bug\n\nThis explains why the fix is needed.\nSecond body line.",
					author_name = "Alice",
					authored_date = "2024-01-02T03:04:05Z",
				},
			}, nil)
		end)
		local api = fresh_module()

		local commits
		api.fetch_commits({ id = 12, repo_full_name = "group/project" }, nil, function(c)
			commits = c
		end)

		assert.equal(1, #commits)
		assert.equal(
			"Fix bug\n\nThis explains why the fix is needed.\nSecond body line.",
			commits[1].message
		)
		assert.equal("abc123def456", commits[1].hash)
		assert.equal("abc123d", commits[1].short_hash)
	end)

	it("falls back to the title when the message field is missing", function()
		stub_service(function(_, _, _, callback)
			callback({
				{ id = "abc123", title = "Fix bug" },
			}, nil)
		end)
		local api = fresh_module()

		local commits
		api.fetch_commits({ id = 12, repo_full_name = "group/project" }, nil, function(c)
			commits = c
		end)

		assert.equal("Fix bug", commits[1].message)
	end)

	it("propagates errors from the request", function()
		stub_service(function(_, _, _, callback)
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
