-- Per-module router for the bitbucket API layer.
--
-- The bitbucket provider supports both Cloud (api.bitbucket.org/2.0) and Server
-- (Bitbucket Data Center, /rest/api/1.0). Response shapes diverge enough that
-- each variant has its own implementation under api/cloud/<module>.lua and api/server/<module>.lua.

local config = require("atlas.config")
local logger = require("atlas.core.logger")

---@return "cloud"|"server"
local function api_type()
	local bb = config.options
			and config.options.pulls
			and config.options.pulls.providers
			and config.options.pulls.providers.bitbucket
		or {}
	return (bb.api_type == "server") and "server" or "cloud"
end

---@param module_name string  e.g. "pullrequests"
---@param fn_name string
local function unsupported(module_name, fn_name)
	return function(...)
		local args = { ... }
		local cb = args[#args]
		local err =
			string.format("bitbucket %s.%s is not supported for api_type=%s yet", module_name, fn_name, api_type())
		logger.logwarn("Bitbucket router: unsupported call", {
			module = module_name,
			fn = fn_name,
			api_type = api_type(),
		})
		if type(cb) == "function" then
			cb(nil, err)
		end
		return nil
	end
end

---@param module_name string
---@return table
local function build(module_name)
	return setmetatable({}, {
		__index = function(_, fn_name)
			local path = string.format("atlas.pulls.providers.bitbucket.api.%s.%s", api_type(), module_name)
			local ok, mod = pcall(require, path)
			local fn = ok and type(mod) == "table" and mod[fn_name] or nil
			if fn ~= nil then
				return fn
			end
			return unsupported(module_name, fn_name)
		end,
	})
end

return build
