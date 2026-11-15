-- https://learn.microsoft.com/en-us/rest/api/azure/devops/?view=azure-devops-rest-7.1

local M = {}

local config = require("atlas.config")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")
local request_scope = require("atlas.core.requests")
local utils = require("atlas.core.utils")

-- https://learn.microsoft.com/en-us/azure/devops/cli/entra-tokens?view=azure-devops
local AZURE_DEVOPS_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"

---@type { token: string|nil, expires_on: integer, waiting: fun(authorization: string|nil, err: string|nil)[]|nil }
local az = { token = nil, expires_on = 0, waiting = nil }

local function azure_config()
	return config.provider_options("azure") or {}
end

---@return string
function M.base_url()
	return (tostring(azure_config().base_url or ""):gsub("/+$", ""))
end

---@return number
local function cache_ttl()
	return tonumber(azure_config().cache_ttl) or 300
end

---@param key string
---@return string
local function cache_key(key)
	return "azure:" .. M.base_url():lower() .. ":" .. key
end

---@param key string
---@return any|nil, boolean
function M.get_cache(key)
	if cache_ttl() <= 0 then
		return nil, false
	end
	local entry = memory_cache.get(cache_key(key))
	if not entry then
		return nil, false
	end
	return entry.value, true
end

---@param key string
---@param value any
---@param ttl? number
function M.set_cache(key, value, ttl)
	if cache_ttl() <= 0 then
		return
	end
	memory_cache.set(cache_key(key), value, ttl or cache_ttl())
end

---@param key string
---@return any|nil, boolean
function M.get_persistent_cache(key)
	if cache_ttl() <= 0 then
		return nil, false
	end

	local entry = cache.get(cache_key(key))
	if not entry or entry.value == nil then
		return nil, false
	end
	return entry.value, true
end

---@param key string
---@param value any
---@param ttl? number
function M.set_persistent_cache(key, value, ttl)
	if cache_ttl() <= 0 then
		return
	end
	cache.set(cache_key(key), value, ttl or cache_ttl())
end

function M.clear_cache()
	memory_cache.clear_prefix(cache_key(""))
	cache.clear_prefix(cache_key(""))
end

M.url_encode = utils.url_encode

---@param params table<string, any>
---@return string
function M.build_query(params)
	local parts = {}
	for key, value in pairs(params) do
		table.insert(parts, key .. "=" .. M.url_encode(tostring(value)))
	end
	table.sort(parts)
	return "?" .. table.concat(parts, "&")
end

---@param authorization string|nil
---@param err string|nil
local function resolve_waiting(authorization, err)
	local waiting = az.waiting or {}
	az.waiting = nil
	for _, callback in ipairs(waiting) do
		callback(authorization, err)
	end
end

---@param on_done fun(authorization: string|nil, err: string|nil)
local function authorization(on_done)
	local token = azure_config().token
	if token and token ~= "" then
		on_done("Basic " .. vim.base64.encode(":" .. token))
		return
	end

	if az.token and os.time() < az.expires_on - 300 then
		on_done("Bearer " .. az.token)
		return
	end

	if az.waiting then
		table.insert(az.waiting, on_done)
		return
	end

	if vim.fn.executable("az") ~= 1 then
		on_done(nil, "Set providers.azure.token or install the Azure CLI and run `az login`")
		return
	end

	az.waiting = { on_done }
	local command = { "az", "account", "get-access-token", "--resource", AZURE_DEVOPS_RESOURCE, "--output", "json" }
	vim.system(
		command,
		{ text = true },
		vim.schedule_wrap(function(result)
			local ok, decoded = pcall(vim.json.decode, result.stdout or "")
			if result.code ~= 0 or not ok or not decoded.accessToken then
				resolve_waiting(nil, "Azure CLI: " .. vim.trim(result.stderr or ""))
				return
			end

			az.token = decoded.accessToken
			az.expires_on = tonumber(decoded.expires_on) or 0
			logger.loginfo("Fetched Azure CLI token", { expires_at = os.date("%Y-%m-%d %H:%M:%S", az.expires_on) })
			-- TODO: remove me
			require("atlas.core.notify").info(
				"Azure CLI token refreshed, expires at " .. os.date("%H:%M", az.expires_on),
				{ vim_notify = true }
			)
			resolve_waiting("Bearer " .. az.token, nil)
		end)
	)
end

---@param method string
---@param endpoint string
---@param data? table
---@param on_done fun(result: any, err: string|nil, headers?: table<string, string>)
---@param ctx? table
---@param opts? { api_version?: string, content_type?: string, response_headers?: boolean }
---@return { cancel: fun() }|nil
function M.request(method, endpoint, data, on_done, ctx, opts)
	opts = opts or {}
	local cfg = azure_config()
	if not cfg.base_url or cfg.base_url == "" then
		local err = "Missing providers.azure.base_url in config"
		logger.logerror("Azure DevOps config missing", { error = err })
		on_done(nil, err)
		return nil
	end

	local payload = data and vim.fn.json_encode(data) or nil
	local separator = endpoint:find("?", 1, true) and "&" or "?"
	endpoint = endpoint .. separator .. "api-version=" .. (opts.api_version or "7.1")

	local log = vim.tbl_extend("keep", { method = method, endpoint = endpoint }, ctx or {})
	local message = log.action or "Azure DevOps request"
	log.action = nil
	logger.loginfo(message, log)

	---@param result any
	---@param err string|nil
	---@param status integer|nil
	---@param headers_out table<string, string>|nil
	local function finish(result, err, status, headers_out)
		if err then
			if status == 401 then
				az.token = nil
			end
			if type(result) == "table" and type(result.message) == "string" and result.message ~= "" then
				err = result.message
			end
			logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(err) }))
			on_done(nil, err)
			return
		end
		if method ~= "GET" and not endpoint:find("/_apis/wit/wiql", 1, true) then
			M.clear_cache()
		end
		on_done(result, nil, headers_out)
	end

	local scope = request_scope.new()
	scope.run(authorization, function(auth, auth_err)
		if not auth then
			finish(nil, auth_err)
			return
		end

		-- X-TFS-FedAuthRedirect is not documented, but based on https://github.com/Azure/azure-sdk-for-go/pull/23485
		-- it makes Azure DevOps return a 401 for a rejected token instead of a redirect to the sign-in page.
		local headers = {
			Authorization = auth,
			["Content-Type"] = opts.content_type or "application/json",
			["Content-Length"] = (method == "POST" or method == "PUT") and payload == nil and "0" or nil,
			Accept = "application/json",
			["X-TFS-FedAuthRedirect"] = "Suppress",
		}
		scope.run(function(done)
			return http.curl_request(method, M.base_url() .. endpoint, headers, payload, done, {
				response_headers = opts.response_headers,
			})
		end, finish)
	end)
	return scope
end

---Fetch every page of a list endpoint that pages with continuation tokens.
---@param endpoint string
---@param params table<string, any>
---@param ctx table
---@param on_done fun(values: table[]|nil, err: string|nil)
---@return AtlasRequestScope
function M.fetch_all(endpoint, params, ctx, on_done)
	local scope = request_scope.new()
	local values = {}

	---@param continuation_token string|nil
	local function fetch_page(continuation_token)
		local query = M.build_query(vim.tbl_extend("force", params, {
			["$top"] = 100,
			continuationToken = continuation_token,
		}))
		scope.run(function(done)
			return M.request("GET", endpoint .. query, nil, done, ctx, { response_headers = true })
		end, function(result, err, headers)
			if err then
				on_done(nil, err)
				return
			end
			vim.list_extend(values, result.value)
			local next_token = headers and headers["x-ms-continuationtoken"]
			if next_token then
				fetch_page(next_token)
				return
			end
			on_done(values, nil)
		end)
	end

	fetch_page(nil)
	return scope
end

return M
