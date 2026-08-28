local M = {}

---@param value any
---@return string
local function one_line(value)
	local s = tostring(value or ""):gsub("[\r\n]+", " | ")
	return s
end

---@param method string
---@param url string
---@param headers table<string, string>
---@param data? string
---@param callback fun(body?: string, status?: integer|nil, err?: string, headers?: table<string, string>)
---@param follow_redirects? boolean
---@return { job_id: integer, cancel: fun() }
local function curl_fetch(method, url, headers, data, callback, follow_redirects)
	local args = { "curl", "-sS" }
	if follow_redirects then
		table.insert(args, "-L")
	end
	vim.list_extend(args, { "-X", method })

	for key, value in pairs(headers or {}) do
		table.insert(args, "-H")
		table.insert(args, string.format("%s: %s", key, value))
	end

	if data then
		table.insert(args, "--data-raw")
		table.insert(args, data)
	end

	table.insert(args, "-w")
	table.insert(args, "__ATLAS_HTTP_CODE:%{http_code}\n%{header_json}")
	table.insert(args, url)

	local out = {}
	local err_out = {}
	local cancelled = false

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
			vim.schedule(function()
				if cancelled then
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

				local body, status_str, header_json = raw:match("^(.*)__ATLAS_HTTP_CODE:(%d+)\n(.*)$")
				local response_headers = {}
				for key, values in pairs(vim.json.decode(header_json)) do
					response_headers[key] = values[1]
				end

				callback(body, tonumber(status_str), nil, response_headers)
			end)
		end,
	}
	local started, result = pcall(vim.fn.jobstart, args, job_opts)
	local job_id = started and result or -1
	if job_id <= 0 then
		local err = started and "Failed to start curl" or one_line(result)
		vim.schedule(function()
			if cancelled then
				return
			end
			callback(nil, nil, err)
		end)
	end

	return {
		job_id = job_id,
		cancel = function()
			cancelled = true
			if job_id and job_id > 0 then
				pcall(vim.fn.jobstop, job_id)
			end
		end,
	}
end

---@param method string HTTP method (GET, POST, PUT, DELETE)
---@param url string Full URL
---@param headers table<string, string> HTTP headers
---@param data? string JSON data for POST/PUT
---@param callback fun(result?: table, err?: string, headers?: table<string, string>)
---@return { job_id: integer, cancel: fun() }
function M.curl_request(method, url, headers, data, callback)
	return curl_fetch(method, url, headers, data, function(body, http_status, err, response_headers)
		if err ~= nil then
			callback(nil, err)
			return
		end

		if body == nil or body == "" then
			if http_status ~= nil and http_status >= 200 and http_status < 300 then
				callback({ __http_status = http_status }, nil, response_headers)
				return
			end
			callback(nil, string.format("HTTP %s", tostring(http_status or "?")))
			return
		end

		if http_status ~= nil and (http_status < 200 or http_status >= 300) then
			local response_text = one_line(body)
			if response_text == "" then
				callback(nil, string.format("HTTP %d", http_status))
			else
				callback(nil, string.format("HTTP %d: %s", http_status, response_text))
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
				)
			)
			return
		end

		if type(result) == "table" then
			result.__http_status = http_status
		end

		callback(result, nil, response_headers)
	end)
end

---@param method string
---@param url string
---@param headers table<string, string>
---@param data? string
---@param callback fun(result?: string, err?: string)
---@return { job_id: integer, cancel: fun() }
function M.curl_text_request(method, url, headers, data, callback)
	return curl_fetch(method, url, headers, data, function(body, http_status, err)
		if err ~= nil then
			callback(nil, err)
			return
		end

		if http_status ~= nil and (http_status < 200 or http_status >= 300) then
			callback(nil, string.format("HTTP %d", http_status))
			return
		end

		callback(body or "", nil)
	end, true)
end

return M
