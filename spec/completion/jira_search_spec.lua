local MODULES = {
	"atlas.issues.providers.jira.completion.search",
	"atlas.ui.prompt",
	"atlas.issues.providers.jira.api.autocomplete",
}

describe("Jira JQL completion", function()
	local previous = {}
	local cached

	---@return fun(query: string): string[]
	local function open()
		local complete
		package.loaded["atlas.ui.prompt"] = {
			open = function(opts)
				complete = opts.complete
			end,
		}
		package.loaded["atlas.issues.providers.jira.api.autocomplete"] = {
			get_data = function() end,
			get_cached_data = function()
				return cached
			end,
		}
		package.loaded["atlas.issues.providers.jira.completion.search"] = nil
		require("atlas.issues.providers.jira.completion.search").edit(nil, function() end)
		return function(query)
			local cmdline = "AtlasJqlSearch " .. query
			return complete("", cmdline, #cmdline)
		end
	end

	before_each(function()
		cached = nil
		for _, name in ipairs(MODULES) do
			previous[name] = package.loaded[name]
		end
	end)

	after_each(function()
		for _, name in ipairs(MODULES) do
			package.loaded[name] = previous[name]
		end
	end)

	it("completes a field, its operators, a matching function and the next clause", function()
		local complete = open()
		for _, case in ipairs({
			{ "st", { "status" } },
			{ "summary ", { "!~ ", "is ", "is not ", "~ " } },
			{ "status is n", { "is not " } },
			{ "assignee = ", { "currentUser()" } },
			{ "assignee = currentUser() a", { "assignee", "AND ", "ASC " } },
			{ "status = Done and pr", { "priority", "project" } },
			{ "status = Done order by pri", { "priority" } },
		}) do
			assert.same(case[2], complete(case[1]), case[1])
		end
	end)

	it("uses the fields Jira returns and quotes names with spaces", function()
		cached = {
			visibleFieldNames = {
				{ value = "Story Points", displayName = "Story Points", operators = { "=", ">" }, types = {} },
			},
		}
		local complete = open()

		assert.same({ '"Story Points"' }, complete("sto"))
		assert.same({ "= ", "> " }, complete('"Story Points" '))
	end)
end)
