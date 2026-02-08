-- common/http.lua: Shared HTTP client using curl
local M = {}

---Execute curl command asynchronously
---@param method string HTTP method (GET, POST, PUT, DELETE)
---@param url string Full URL
---@param headers table<string, string> HTTP headers
---@param data? string JSON data for POST/PUT
---@param callback? fun(result?: table, err?: string)
function M.curl_request(method, url, headers, data, callback)
  -- Build headers
  local header_args = {}
  for key, value in pairs(headers) do
    table.insert(header_args, string.format('-H "%s: %s"', key, value))
  end
  local header_str = table.concat(header_args, " ")

  -- Build curl command
  local cmd
  if data then
    cmd = string.format(
      'curl -s -X %s %s -d \'%s\' "%s"',
      method,
      header_str,
      data,
      url
    )
  else
    cmd = string.format(
      'curl -s -X %s %s "%s"',
      method,
      header_str,
      url
    )
  end

  -- Execute async
  local stdout_data = {}
  local stderr_data = {}
  
  vim.fn.jobstart(cmd, {
    on_stdout = function(_, output)
      for _, line in ipairs(output) do
        if line ~= "" then
          table.insert(stdout_data, line)
        end
      end
    end,
    on_stderr = function(_, output)
      for _, line in ipairs(output) do
        if line ~= "" then
          table.insert(stderr_data, line)
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        local err = "curl exited with code " .. code
        if #stderr_data > 0 then
          err = err .. ": " .. table.concat(stderr_data, "\n")
        end
        if callback and vim.is_callable(callback) then
          callback(nil, err)
        end
        return
      end

      if #stdout_data == 0 then
        if callback and vim.is_callable(callback) then
          callback(nil, "Empty response from server")
        end
        return
      end

      local raw = table.concat(stdout_data, "\n")
      local ok, result = pcall(vim.json.decode, raw)

      if not ok then
        if callback and vim.is_callable(callback) then
          callback(nil, "Failed to parse JSON: " .. tostring(result) .. "\nRaw: " .. raw:sub(1, 200))
        end
        return
      end

      if callback and vim.is_callable(callback) then
        callback(result, nil)
      end
    end,
  })
end

return M
