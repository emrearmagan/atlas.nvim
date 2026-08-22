local original = {
	tbl_extend = vim.tbl_extend,
	islist = vim.islist,
	empty_dict = vim.empty_dict,
	json_encode = vim.fn.json_encode,
}

local dependency_names = {
	"atlas.config",
	"atlas.core.http",
	"atlas.core.memory_cache",
	"atlas.core.cache",
	"atlas.core.logger",
}

local calls
local provider_config

local function load_client()
	package.loaded["atlas.providers.gitlab.client"] = nil
	return require("atlas.providers.gitlab.client")
end

describe("GitLab client", function()
	before_each(function()
		calls = {}
		provider_config = {}
		rawset(vim, "tbl_extend", function(_, first, second)
			local result = {}
			for key, value in pairs(second) do
				result[key] = value
			end
			for key, value in pairs(first) do
				result[key] = value
			end
			return result
		end)
		vim.islist = function(_)
			return false
		end
		vim.empty_dict = function()
			return {}
		end
		rawset(vim.fn, "json_encode", function(_)
			return "{}"
		end)

		package.preload["atlas.config"] = function()
			return {
				provider_options = function(id)
					return id == "gitlab" and provider_config or nil
				end,
			}
		end
		package.preload["atlas.core.http"] = function()
			return {
				curl_request = function(method, url, headers, body, on_done)
					table.insert(calls, { method = method, url = url, headers = headers, body = body })
					if url:find("/api/graphql", 1, true) then
						on_done({ data = { ok = true } }, nil)
					else
						on_done({}, nil)
					end
					return { job_id = 1, cancel = function() end }
				end,
				curl_text_request = function() end,
			}
		end
		package.preload["atlas.core.memory_cache"] = function()
			return { clear_all = function() end, get = function() end, set = function() end, delete = function() end }
		end
		package.preload["atlas.core.cache"] = package.preload["atlas.core.memory_cache"]
		package.preload["atlas.core.logger"] = function()
			return { loginfo = function() end, logerror = function() end }
		end
		for _, name in ipairs(dependency_names) do
			package.loaded[name] = nil
		end
	end)

	after_each(function()
		vim.tbl_extend = original.tbl_extend
		vim.islist = original.islist
		vim.empty_dict = original.empty_dict
		vim.fn.json_encode = original.json_encode
		package.loaded["atlas.providers.gitlab.client"] = nil
		for _, name in ipairs(dependency_names) do
			package.loaded[name] = nil
			package.preload[name] = nil
		end
	end)

	it("preserves self-hosted path prefixes for REST and GraphQL", function()
		provider_config.base_url = "https://gitlab.example.com/company/gitlab///"
		provider_config.token = "secret"
		local client = load_client().pulls

		client.request("GET", "/projects", nil, function() end)
		client.graphql("query { currentUser { id } }", nil, function() end)

		assert.equal("https://gitlab.example.com/company/gitlab/api/v4/projects", calls[1].url)
		assert.equal("https://gitlab.example.com/company/gitlab/api/graphql", calls[2].url)
	end)

	it("requires GraphQL authentication", function()
		local client = load_client().pulls
		local auth_err
		client.graphql("query { currentUser { id } }", nil, function(_, err)
			auth_err = err
		end)

		assert.equal("Missing GitLab credentials in config", auth_err)
		assert.equal(0, #calls)
	end)
end)
