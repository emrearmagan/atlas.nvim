local M = {}

local cache = require("atlas.core.cache")
local config = require("atlas.config")
local logger = require("atlas.core.logger")
local memory = require("atlas.core.memory_cache")

local DEFAULT_CACHE_TTL = 300

---@param store table
---@param key string
---@return any|nil, boolean
local function get_cached(store, key)
	local entry = store.get(key)
	if entry and entry.value ~= nil then
		return entry.value, true
	end
	return nil, false
end

---@param err string|nil
---@return string
local function sanitize_error(err)
	if not err or err == "" then
		return "Unknown error"
	end
	return (err:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.github_config()
	return config.provider_options("github") or {}
end

function M.cache_ttl()
	return tonumber(M.github_config().cache_ttl) or DEFAULT_CACHE_TTL
end

function M.get_cache(key)
	return get_cached(cache, key)
end

function M.set_cache(key, value, ttl)
	cache.set(key, value, ttl or M.cache_ttl())
end

function M.delete_cache(key)
	cache.delete(key)
end

function M.get_mem(key)
	return get_cached(memory, key)
end

function M.set_mem(key, value, ttl)
	memory.set(key, value, ttl)
end

function M.delete_mem(key)
	memory.delete(key)
end

---@param args string[]
---@param parse_json boolean
---@param callback fun(result: any, err: string|nil)
---@param ctx table|nil
---@return { job_id: integer, cancel: fun() }|nil
local function run(args, parse_json, callback, ctx)
	local log = vim.tbl_extend("keep", {}, ctx or {})
	local message = log.action or "GitHub CLI"
	log.action = nil
	logger.loginfo(message, log)

	if vim.fn.executable("gh") ~= 1 then
		logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = "gh executable not found" }))
		vim.schedule(function()
			callback(nil, "gh CLI not found. Install from https://cli.github.com")
		end)
		return nil
	end

	local cmd = vim.list_extend({ "gh" }, args)
	local cancelled = false
	local function on_exit(result)
		vim.schedule(function()
			if cancelled then
				return
			end
			if result.code ~= 0 then
				local err = sanitize_error(result.stderr)
				logger.logerror(
					message .. " failed",
					vim.tbl_extend("force", {}, log, { code = result.code, error = err })
				)
				callback(nil, err)
				return
			end

			local stdout = result.stdout or ""
			if parse_json then
				stdout = vim.trim(stdout)
			end
			if stdout == "" then
				callback(nil, nil)
				return
			end

			if parse_json then
				local ok, parsed = pcall(vim.json.decode, stdout)
				if ok then
					callback(parsed, nil)
					return
				end
			end
			callback(stdout, nil)
		end)
	end

	local started, handle = pcall(vim.system, cmd, { text = true }, on_exit)
	if not started then
		logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(handle) }))
		vim.schedule(function()
			callback(nil, "Failed to start gh process")
		end)
		return nil
	end

	return {
		job_id = handle.pid,
		cancel = function()
			cancelled = true
			pcall(function()
				handle:kill(9)
			end)
		end,
	}
end

function M.gh(args, callback, ctx)
	return run(args, true, callback, ctx)
end

function M.gh_text(args, callback, ctx)
	return run(args, false, callback, ctx)
end

function M.api(method, endpoint, body, callback, ctx)
	local args = { "api", "-X", method, endpoint }
	if body then
		for key, value in pairs(body) do
			table.insert(args, "-f")
			table.insert(args, string.format("%s=%s", key, tostring(value)))
		end
	end
	return M.gh(
		args,
		callback,
		vim.tbl_extend("keep", ctx or {}, {
			method = method,
			endpoint = endpoint,
		})
	)
end

return M
