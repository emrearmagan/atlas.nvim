local M = {}

local logger = require("atlas.core.logger")

---@param value any
---@return string
local function one_line(value)
	local s = tostring(value or ""):gsub("[\r\n]+", " | ")
	return s
end

---@param value any
---@return string
local function curl_config_value(value)
	local escaped = tostring(value or "")
		:gsub("\\", "\\\\")
		:gsub('"', '\\"')
		:gsub("\t", "\\t")
		:gsub("\n", "\\n")
		:gsub("\r", "\\r")
		:gsub("\v", "\\v")
	return '"' .. escaped .. '"'
end

---@param method string
---@param url string
---@param headers table<string, string>
---@param data? string
---@param callback fun(body?: string, status?: integer|nil, err?: string)
---@param follow_redirects? boolean
---@return { job_id: integer, cancel: fun() }
local function curl_fetch(method, url, headers, data, callback, follow_redirects)
	local config = {
		"silent",
		"show-error",
		"request = " .. curl_config_value(method),
	}
	if follow_redirects then
		table.insert(config, "location")
	end

	for key, value in pairs(headers or {}) do
		table.insert(config, "header = " .. curl_config_value(string.format("%s: %s", key, value)))
	end

	if data then
		table.insert(config, "data-raw = " .. curl_config_value(data))
	end

	table.insert(config, "write-out = " .. curl_config_value("__ATLAS_HTTP_CODE:%{http_code}"))
	table.insert(config, "url = " .. curl_config_value(url))
	local config_input = table.concat(config, "\n") .. "\n"
	local args = { "curl", "--config", "-" }

	local cancelled = false
	local finished = false
	local function on_exit(result)
		vim.schedule(function()
			if cancelled then
				return
			end
			finished = true

			local raw = result.stdout or ""
			if result.code ~= 0 then
				local err = "curl exited with code " .. tostring(result.code)
				if result.stderr and result.stderr ~= "" then
					err = err .. ": " .. one_line(result.stderr)
				end
				callback(nil, nil, err)
				return
			end

			if raw == "" then
				callback(nil, nil, "Empty response from server")
				return
			end

			local body = raw
			local http_status = nil
			local marker_start, _, status_str = raw:find("__ATLAS_HTTP_CODE:(%d+)%s*$")
			if marker_start ~= nil then
				body = raw:sub(1, marker_start - 1)
				http_status = tonumber(status_str)
			end

			callback(body, http_status, nil)
		end)
	end

	local started, handle = pcall(vim.system, args, { text = true, stdin = config_input }, on_exit)
	if not started then
		local err = one_line(handle)
		logger.logerror("HTTP request failed to start", { method = method, url = url, error = err })
		vim.schedule(function()
			if not cancelled then
				finished = true
				callback(nil, nil, err)
			end
		end)
	end

	return {
		job_id = started and handle.pid or -1,
		cancel = function()
			if cancelled or finished then
				return
			end
			cancelled = true
			if started then
				pcall(handle.kill, handle, 9)
			end
		end,
	}
end

---@param method string HTTP method (GET, POST, PUT, DELETE)
---@param url string Full URL
---@param headers table<string, string> HTTP headers
---@param data? string JSON data for POST/PUT
---@param callback fun(result?: table, err?: string, status?: integer)
---@return { job_id: integer, cancel: fun() }
function M.curl_request(method, url, headers, data, callback)
	return curl_fetch(method, url, headers, data, function(body, http_status, err)
		if err ~= nil then
			callback(nil, err, http_status)
			return
		end

		if body == nil or body == "" then
			if http_status ~= nil and http_status >= 200 and http_status < 300 then
				callback({ __http_status = http_status }, nil, http_status)
				return
			end
			callback(nil, string.format("HTTP %s", tostring(http_status or "?")), http_status)
			return
		end

		if http_status ~= nil and (http_status < 200 or http_status >= 300) then
			local response_text = one_line(body)
			if response_text == "" then
				callback(nil, string.format("HTTP %d", http_status), http_status)
			else
				callback(nil, string.format("HTTP %d: %s", http_status, response_text), http_status)
			end
			return
		end

		local ok, result = pcall(vim.json.decode, body)
		if not ok then
			callback(
				nil,
				string.format(
					"Failed to parse JSON response (HTTP %s): %s",
					tostring(http_status or "?"),
					one_line(result)
				),
				http_status
			)
			return
		end

		if type(result) == "table" then
			result.__http_status = http_status
		end

		callback(result, nil, http_status)
	end)
end

---@param method string
---@param url string
---@param headers table<string, string>
---@param data? string
---@param callback fun(result?: string, err?: string, status?: integer)
---@return { job_id: integer, cancel: fun() }
function M.curl_text_request(method, url, headers, data, callback)
	return curl_fetch(method, url, headers, data, function(body, http_status, err)
		if err ~= nil then
			callback(nil, err, http_status)
			return
		end

		if http_status ~= nil and (http_status < 200 or http_status >= 300) then
			callback(nil, string.format("HTTP %d", http_status), http_status)
			return
		end

		callback(body or "", nil, http_status)
	end, true)
end

return M
