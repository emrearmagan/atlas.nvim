local M = {}

-- Lots of views can throw a curl party so here is that
local MAX_CONCURRENT_REQUESTS = 10
local running = 0
local queue = {}

local function drain()
	while running < MAX_CONCURRENT_REQUESTS and #queue > 0 do
		table.remove(queue, 1)()
	end
end

local function release_slot()
	running = running - 1
	vim.schedule(drain)
end

---@param value any
---@return string
local function one_line(value)
	local s = tostring(value or ""):gsub("[\r\n]+", " | ")
	return s
end

---@param value string
---@return string
local function curl_config_value(value)
	local escaped = value
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
---@param callback fun(body?: string, status?: integer|nil, err?: string, headers?: table<string, string>)
---@param follow_redirects? boolean
---@param with_headers? boolean
---@return { job_id: integer, cancel: fun() }
local function curl_fetch(method, url, headers, data, callback, follow_redirects, with_headers)
	local config = {
		"silent",
		"show-error",
		"globoff",
		"connect-timeout = 10",
		"max-time = 60",
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

	local write_out = "__ATLAS_HTTP_CODE:%{http_code}"
	if with_headers then
		write_out = write_out .. "\n__ATLAS_HTTP_HEADERS:%{header_json}"
	end
	table.insert(config, "write-out = " .. curl_config_value(write_out))
	table.insert(config, "url = " .. curl_config_value(url))
	local config_input = table.concat(config, "\n") .. "\n"
	local args = { "curl", "--config", "-" }

	local out = {}
	local err_out = {}
	local cancelled = false
	local input_error
	local handle = { job_id = -1 }

	local job_opts = {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, response)
			if response then
				vim.list_extend(out, response)
			end
		end,
		on_stderr = function(_, response)
			if response then
				vim.list_extend(err_out, response)
			end
		end,
		on_exit = function(_, code)
			release_slot()
			vim.schedule(function()
				if cancelled or input_error then
					return
				end

				local raw = table.concat(out, "\n")
				local stderr_text = table.concat(err_out, "\n")

				if code ~= 0 then
					local err = "curl exited with code " .. tostring(code)
					if stderr_text ~= "" then
						err = err .. ": " .. one_line(stderr_text)
					end
					callback(nil, nil, err)
					return
				end

				if raw == "" then
					callback(nil, nil, "Empty response from server")
					return
				end

				local response_headers = nil
				local headers_start, _, header_json = raw:find("\n__ATLAS_HTTP_HEADERS:(.*)$")
				if headers_start ~= nil then
					raw = raw:sub(1, headers_start - 1)
					local ok, parsed = pcall(vim.json.decode, header_json)
					if ok and type(parsed) == "table" then
						response_headers = {}
						for key, values in pairs(parsed) do
							response_headers[key] = values[1]
						end
					end
				end

				local body = raw
				local http_status = nil
				local marker_start, _, status_str = raw:find("__ATLAS_HTTP_CODE:(%d+)%s*$")
				if marker_start ~= nil then
					body = raw:sub(1, marker_start - 1)
					http_status = tonumber(status_str)
				end

				callback(body, http_status, nil, response_headers)
			end)
		end,
	}
	local function start()
		if cancelled then
			return
		end
		running = running + 1
		local started, result = pcall(vim.fn.jobstart, args, job_opts)
		local job_id = started and result or -1
		handle.job_id = job_id
		if job_id <= 0 then
			release_slot()
			local err = started and "Failed to start curl" or one_line(result)
			vim.schedule(function()
				if cancelled then
					return
				end
				callback(nil, nil, err)
			end)
		else
			local sent, err = pcall(function()
				assert(vim.fn.chansend(job_id, config_input) > 0, "Failed to send curl configuration")
				vim.fn.chanclose(job_id, "stdin")
			end)
			if not sent then
				input_error = one_line(err)
				pcall(vim.fn.jobstop, job_id)
				vim.schedule(function()
					if not cancelled then
						callback(nil, nil, input_error)
					end
				end)
			end
		end
	end

	function handle.cancel()
		cancelled = true
		if handle.job_id > 0 then
			pcall(vim.fn.jobstop, handle.job_id)
		end
	end

	table.insert(queue, start)
	drain()
	return handle
end

---@param method string HTTP method (GET, POST, PUT, DELETE)
---@param url string Full URL
---@param headers table<string, string> HTTP headers
---@param data? string JSON data for POST/PUT
---@param callback fun(result?: table, err?: string, status?: integer, headers?: table<string, string>)
---@param opts? { response_headers?: boolean }
---@return { job_id: integer, cancel: fun() }
function M.curl_request(method, url, headers, data, callback, opts)
	return curl_fetch(method, url, headers, data, function(body, http_status, err, response_headers)
		if err ~= nil then
			callback(nil, err, http_status)
			return
		end

		if body == nil or body == "" then
			if http_status ~= nil and http_status >= 200 and http_status < 300 then
				callback({}, nil, http_status, response_headers)
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

		callback(result, nil, http_status, response_headers)
	end, method == "GET", opts and opts.response_headers)
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
