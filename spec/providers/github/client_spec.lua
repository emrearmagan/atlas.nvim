local dependencies = {
	"atlas.providers.github.client",
	"atlas.config",
	"atlas.core.cache",
	"atlas.core.memory_cache",
	"atlas.core.logger",
}

local function store()
	local entries = {}
	return {
		get = function(key)
			return entries[key]
		end,
		set = function(key, value)
			entries[key] = { value = value }
		end,
		delete = function(key)
			entries[key] = nil
		end,
	}
end

describe("GitHub client host routing", function()
	local saved, original, options, calls, client

	before_each(function()
		saved = {}
		for _, name in ipairs(dependencies) do
			saved[name] = { loaded = package.loaded[name], preload = package.preload[name] }
			package.loaded[name] = nil
			package.preload[name] = nil
		end
		original = {
			system = vim.system,
			executable = vim.fn.executable,
			decode = vim.json.decode,
			gh_host = vim.env.GH_HOST,
		}
		options, calls = {}, {}
		vim.env.GH_HOST = nil
		package.loaded["atlas.config"] = {
			provider_options = function()
				return options
			end,
		}
		package.loaded["atlas.core.cache"] = store()
		package.loaded["atlas.core.memory_cache"] = store()
		package.loaded["atlas.core.logger"] = { loginfo = function() end, logerror = function() end }
		vim.fn.executable = function()
			return 1
		end
		vim.json.decode = function(value)
			assert.are.equal('{"ok":true}', value)
			return { ok = true }
		end
		vim.system = function(cmd, opts, on_exit)
			local call = { cmd = cmd, opts = opts, on_exit = on_exit }
			table.insert(calls, call)
			return {
				pid = #calls,
				kill = function()
					call.killed = true
				end,
			}
		end
		client = require("atlas.providers.github.client")
	end)

	after_each(function()
		vim.system = original.system
		vim.fn.executable = original.executable
		vim.json.decode = original.decode
		vim.env.GH_HOST = original.gh_host
		for _, name in ipairs(dependencies) do
			package.loaded[name] = saved[name].loaded
			package.preload[name] = saved[name].preload
		end
	end)

	it("uses an explicit hostname ahead of GH_HOST without changing Neovim's environment", function()
		vim.env.GH_HOST = "other.example.com"
		options.hostname = " GitHub.Company.com "
		assert.is_true(client.is_enterprise_server())
		local args = { "api", "graphql", "-f", "query={viewer{login}}" }
		client.gh(args, function() end)
		assert.same({ "gh", "api", "graphql", "-f", "query={viewer{login}}" }, calls[1].cmd)
		assert.are.equal("github.company.com", calls[1].opts.env.GH_HOST)
		assert.are.equal("other.example.com", vim.env.GH_HOST)
		assert.are.equal(4, #args)
		options.hostname = "github.com"
		assert.is_false(client.is_enterprise_server())
	end)

	it("uses GH_HOST when no hostname is configured", function()
		vim.env.GH_HOST = "github.company.com"
		assert.is_true(client.is_enterprise_server())
		client.gh({ "api", "user" }, function() end)
		assert.are.equal("github.company.com", calls[1].opts.env.GH_HOST)
	end)

	it("explicitly defaults API requests to github.com", function()
		assert.is_false(client.is_enterprise_server())
		client.gh({ "api", "user" }, function() end)
		assert.same({ "gh", "api", "user" }, calls[1].cmd)
		assert.are.equal("github.com", calls[1].opts.env.GH_HOST)
	end)

	it("routes repository and search commands using GH_HOST without an unsupported flag", function()
		options.hostname = "github.company.com"
		local commands = {
			{ "pr", "view", "7", "--repo", "owner/repo", "--json", "title" },
			{ "issue", "edit", "7", "--repo", "owner/repo", "--title", "Updated" },
			{ "repo", "view", "owner/repo", "--json", "nameWithOwner" },
			{ "search", "repos", "atlas", "--json", "fullName" },
		}
		for index, args in ipairs(commands) do
			client.gh(args, function() end)
			assert.same(vim.list_extend({ "gh" }, args), calls[index].cmd)
			assert.are.equal("github.company.com", calls[index].opts.env.GH_HOST)
		end
	end)

	it("isolates persistent and memory entries with the same key between hosts", function()
		for _, kind in ipairs({ "cache", "mem" }) do
			options.hostname = "github.com"
			client["set_" .. kind]("github:user:me", { login = "public-user" })
			options.hostname = "github.company.com"
			assert.is_nil(client["get_" .. kind]("github:user:me"))
			client["set_" .. kind]("github:user:me", { login = "enterprise-user" })
			assert.same({ login = "enterprise-user" }, client["get_" .. kind]("github:user:me"))
			if kind == "mem" then
				client.delete_mem("github:user:me")
				assert.is_nil(client.get_mem("github:user:me"))
			end
			options.hostname = "github.com"
			assert.same({ login = "public-user" }, client["get_" .. kind]("github:user:me"))
		end
	end)
end)
