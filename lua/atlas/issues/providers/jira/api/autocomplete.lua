local M = {}

local service = require("atlas.issues.providers.jira.api.service")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")

local CACHE_KEY = "jira:jql:autocompletedata"

---@class JiraJqlAutocompleteField
---@field value string
---@field displayName string
---@field operators string[]
---@field types string[]

---@class JiraJqlAutocompleteFunction
---@field value string
---@field types string[]

---@class JiraJqlAutocompleteData
---@field visibleFieldNames JiraJqlAutocompleteField[]
---@field visibleFunctionNames JiraJqlAutocompleteFunction[]
---@field jqlReservedWords string[]

---@param values any
---@return string[]
local function sanitize_string_list(values)
	local out = {}
	if type(values) ~= "table" then
		return out
	end

	for _, value in ipairs(values) do
		if type(value) == "string" then
			local v = vim.trim(value)
			if v ~= "" then
				table.insert(out, v)
			end
		end
	end

	return out
end

---@param raw any
---@return JiraJqlAutocompleteData
local function normalize_payload(raw)
	---@type JiraJqlAutocompleteData
	local out = {
		visibleFieldNames = {},
		visibleFunctionNames = {},
		jqlReservedWords = {},
	}

	if type(raw) ~= "table" then
		return out
	end

	for _, field in ipairs(raw.visibleFieldNames or {}) do
		if type(field) == "table" then
			local value = vim.trim(tostring(field.value or ""))
			if value ~= "" then
				table.insert(out.visibleFieldNames, {
					value = value,
					displayName = vim.trim(tostring(field.displayName or value)),
					operators = sanitize_string_list(field.operators),
					types = sanitize_string_list(field.types),
				})
			end
		end
	end

	for _, fn in ipairs(raw.visibleFunctionNames or {}) do
		if type(fn) == "table" then
			local value = vim.trim(tostring(fn.value or ""))
			if value ~= "" then
				table.insert(out.visibleFunctionNames, {
					value = value,
					types = sanitize_string_list(fn.types),
				})
			end
		elseif type(fn) == "string" then
			local value = vim.trim(fn)
			if value ~= "" then
				table.insert(out.visibleFunctionNames, {
					value = value,
					types = {},
				})
			end
		end
	end

	out.jqlReservedWords = sanitize_string_list(raw.jqlReservedWords)

	return out
end

---@return JiraJqlAutocompleteData|nil, boolean
function M.get_cached_data()
	local entry = cache.get(CACHE_KEY)
	if not entry or type(entry.value) ~= "table" then
		return nil, false
	end

	local normalized = normalize_payload(entry.value)
	cache.set(CACHE_KEY, normalized, service.cache_ttl())
	return normalized, true
end

---@param on_done fun(data: JiraJqlAutocompleteData|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_data(on_done, opts)
	opts = opts or {}

	if not opts.force_load then
		local cached, ok = M.get_cached_data()
		if ok then
			logger.loginfo("Jira autocomplete cache hit")
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", "/jql/autocompletedata", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local normalized = normalize_payload(result)
		cache.set(CACHE_KEY, normalized, service.cache_ttl())
		on_done(normalized, nil)
	end, {
		action = "Fetch jql autocomplete data",
	})
end

return M
