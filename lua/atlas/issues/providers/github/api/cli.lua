local M = {}

local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")

local DEFAULT_CACHE_TTL = 300

---@return AtlasGitHubIssuesConfig
function M.github_config()
	local config = require("atlas.config")
	return ((config.options.issues or {}).providers or {}).github or {}
end

---@return number
function M.cache_ttl()
	return tonumber(M.github_config().cache_ttl) or DEFAULT_CACHE_TTL
end

---@param key string
---@return any|nil, boolean
function M.get_cache(key)
	local entry = cache.get(key)
	if entry and entry.value ~= nil then
		return entry.value, true
	end
	return nil, false
end

---@param key string
---@param value any
---@param ttl number|nil
function M.set_cache(key, value, ttl)
	cache.set(key, value, ttl or M.cache_ttl())
end

---@param key string
function M.delete_cache(key)
	cache.delete(key)
end

local memory = require("atlas.core.memory_cache")

---@param key string
---@return any|nil, boolean
function M.get_mem(key)
	local entry = memory.get(key)
	if entry and entry.value ~= nil then
		return entry.value, true
	end
	return nil, false
end

---@param key string
---@param value any
---@param ttl number|nil
function M.set_mem(key, value, ttl)
	memory.set(key, value, ttl)
end

---@param key string
function M.delete_mem(key)
	memory.delete(key)
end

---@param err string|nil
---@return string
local function sanitize_error(err)
	if not err or err == "" then
		return "Unknown error"
	end
	return err:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

---@param args string[]
---@param callback fun(result: any, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.gh(args, callback)
	if vim.fn.executable("gh") ~= 1 then
		vim.schedule(function()
			callback(nil, "gh CLI not found. Install from https://cli.github.com")
		end)
		return nil
	end

	local cmd = vim.list_extend({ "gh" }, args)
	logger.loginfo("GitHub CLI", { cmd = table.concat(cmd, " ") })

	local cancelled = false

	local handle = vim.system(cmd, { text = true }, function(res)
		vim.schedule(function()
			if cancelled then
				return
			end
			if res.code ~= 0 then
				local err = sanitize_error(res.stderr)
				logger.logerror("GitHub CLI error", { code = res.code, err = err })
				callback(nil, err)
				return
			end

			local stdout = vim.trim(res.stdout or "")
			if stdout == "" then
				callback(nil, nil)
				return
			end

			local ok, parsed = pcall(vim.json.decode, stdout)
			if ok then
				callback(parsed, nil)
			else
				callback(stdout, nil)
			end
		end)
	end)

	if not handle then
		vim.schedule(function()
			callback(nil, "Failed to start gh process")
		end)
		return nil
	end

	local pid = handle.pid
	return {
		job_id = pid,
		cancel = function()
			cancelled = true
			pcall(function()
				handle:kill(9)
			end)
		end,
	}
end

---@param subcmd string
---@param args string[]
---@param json_fields string[]
---@param callback fun(result: any, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.gh_json(subcmd, args, json_fields, callback)
	local cmd_args = { subcmd }
	vim.list_extend(cmd_args, args)
	if #json_fields > 0 then
		table.insert(cmd_args, "--json")
		table.insert(cmd_args, table.concat(json_fields, ","))
	end
	return M.gh(cmd_args, callback)
end

---@param method string
---@param endpoint string
---@param body table|nil
---@param callback fun(result: any, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.api(method, endpoint, body, callback)
	local args = { "api", "-X", method, endpoint }

	if body then
		for k, v in pairs(body) do
			table.insert(args, "-f")
			table.insert(args, string.format("%s=%s", k, tostring(v)))
		end
	end

	return M.gh(args, callback)
end

return M
