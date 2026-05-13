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
---@param callback fun(body?: string, status?: integer|nil, err?: string)
---@return { job_id: integer, cancel: fun() }
local function curl_fetch(method, url, headers, data, callback)
	local args = { "curl", "-sS", "-X", method }

	for key, value in pairs(headers or {}) do
		table.insert(args, "-H")
		table.insert(args, string.format("%s: %s", key, value))
	end

	if data then
		table.insert(args, "--data-raw")
		table.insert(args, data)
	end

	table.insert(args, "-w")
	table.insert(args, "__ATLAS_HTTP_CODE:%{http_code}")
	table.insert(args, url)

	local out = {}
	local err_out = {}
	local cancelled = false

	local job_id = vim.fn.jobstart(args, {
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

				local body = raw
				local http_status = nil
				local marker_start, _, status_str = raw:find("__ATLAS_HTTP_CODE:(%d+)%s*$")
				if marker_start ~= nil then
					body = raw:sub(1, marker_start - 1)
					http_status = tonumber(status_str)
				end

				callback(body, http_status, nil)
			end)
		end,
	})

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
---@param callback fun(result?: table, err?: string)
---@return { job_id: integer, cancel: fun() }
function M.curl_request(method, url, headers, data, callback)
	return curl_fetch(method, url, headers, data, function(body, http_status, err)
		if err ~= nil then
			callback(nil, err)
			return
		end

		if body == nil or body == "" then
			if http_status ~= nil and http_status >= 200 and http_status < 300 then
				callback({ __http_status = http_status }, nil)
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

		callback(result, nil)
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
	end)
end

return M
