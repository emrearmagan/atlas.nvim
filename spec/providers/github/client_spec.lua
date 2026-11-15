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
		---@diagnostic disable-next-line: redundant-parameter
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
		vim.env.GH_HOST = original.gh_host
		for _, name in ipairs(dependencies) do
			package.loaded[name] = saved[name].loaded
			package.preload[name] = saved[name].preload
		end
	end)

	it("routes requests to the hostname, then GH_HOST, then github.com without changing either", function()
		for _, case in ipairs({
			{ hostname = " GitHub.Company.com ", gh_host = "other.example.com", expected = "github.company.com" },
			{ gh_host = "github.company.com", expected = "github.company.com" },
			{ expected = "github.com" },
		}) do
			options.hostname, vim.env.GH_HOST = case.hostname, case.gh_host
			local args = { "api", "user" }
			client.gh(args, function() end)

			assert.same({ "gh", "api", "user" }, calls[#calls].cmd)
			assert.are.equal(case.expected, calls[#calls].opts.env.GH_HOST)
			assert.are.equal(case.expected ~= "github.com", client.is_enterprise_server())
			assert.same({ "api", "user" }, args)
			assert.are.equal(case.gh_host, vim.env.GH_HOST)
		end
	end)

	it("strips the protocol and path from the hostname", function()
		for _, hostname in ipairs({
			"https://github.company.com",
			"HTTPS://GitHub.Company.com/",
			" github.company.com/owner/repo ",
		}) do
			options.hostname = hostname
			assert.are.equal("github.company.com", client.hostname())
		end
	end)
end)
