local github_client = require("spec.support.github_client_stub")

local MODULES = {
	"atlas.providers.github.completion.search",
	"atlas.ui.prompt",
	"atlas.core.git",
	"atlas.issues.providers.github.api.issues",
}

describe("GitHub search completion", function()
	local previous = {}
	local requested
	local types_by_repo

	---@param local_repo string|nil
	---@param default string|nil
	---@return fun(query: string): string[]
	local function open(local_repo, default)
		local mem = {}
		github_client.install({
			get_cache = function(key)
				return mem[key], mem[key] ~= nil
			end,
			set_cache = function(key, value)
				mem[key] = value
			end,
		})
		package.loaded["atlas.core.git"] = {
			local_repository = function(_, on_done)
				on_done(local_repo and { provider = "github", repo_full_name = local_repo } or nil)
			end,
		}
		package.loaded["atlas.issues.providers.github.api.issues"] = {
			list_issue_types = function(slug, on_done)
				table.insert(requested, slug)
				local names = types_by_repo[slug]
				on_done(names and vim.tbl_map(function(name)
					return { name = name }
				end, names) or nil, names == nil and "not found" or nil)
			end,
		}
		local complete
		package.loaded["atlas.ui.prompt"] = {
			open = function(opts)
				complete = opts.complete
			end,
		}
		package.loaded["atlas.providers.github.completion.search"] = nil
		require("atlas.providers.github.completion.search").edit(default, function() end)
		return function(query)
			local cmdline = "AtlasGitHubSearch " .. query
			return complete("", cmdline, #cmdline)
		end
	end

	before_each(function()
		requested = {}
		types_by_repo = {}
		for _, name in ipairs(MODULES) do
			previous[name] = package.loaded[name]
		end
	end)

	after_each(function()
		github_client.uninstall()
		for _, name in ipairs(MODULES) do
			package.loaded[name] = previous[name]
		end
	end)

	it("suggests the default issue types without a repository", function()
		local complete = open(nil)

		assert.same({ "type:Bug", "type:Feature", "type:Task" }, complete("is:issue type:"))
		assert.same({}, requested)
	end)

	it("suggests the local repository's types and quotes names with spaces", function()
		types_by_repo["owner/local"] = { "Bug", "User Story" }
		local complete = open("owner/local")

		assert.same({ 'type:"User Story"', "type:Bug" }, complete("type:"))
		assert.same({ 'type:"User Story"' }, complete('type:"us'))
		assert.same({ "owner/local" }, requested)
	end)

	it("prefers the repository named in the query and fetches it once", function()
		types_by_repo["owner/local"] = { "Bug" }
		types_by_repo["cli/cli"] = { "Task", "Epic" }
		local complete = open("owner/local", "repo:cli/cli is:issue ")

		assert.same({ "type:Epic" }, complete("repo:cli/cli type:Ep"))
		complete("repo:cli/cli type:")
		assert.same({ "owner/local", "cli/cli" }, requested)
	end)

	it("keeps the defaults when the types cannot be loaded", function()
		local complete = open("owner/missing")

		assert.same({ "type:Bug", "type:Feature", "type:Task" }, complete("type:"))
	end)
end)
