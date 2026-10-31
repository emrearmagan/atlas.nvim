local M = {}

local config = require("atlas.config")

---@class AtlasParsedUrl
---@field host string
---@field path string
---@field remote boolean

---@param host string
---@param path string
---@param remote boolean
---@return AtlasParsedUrl
local function normalized(host, path, remote)
	path = path:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end):gsub("/+$", "")
	return { host = host:lower(), path = path, remote = remote }
end

---@param value string
---@return AtlasParsedUrl|nil, string|nil
function M.parse(value)
	if value == "" then
		return nil, "Missing URL"
	end

	local ssh_host, ssh_path = value:match("^[^/@:]+@([^/:]+):(.+)$")
	if ssh_host then
		return normalized(ssh_host, "/" .. ssh_path:gsub("^/+", ""), true)
	end

	local scheme, authority, path = value:match("^([%a][%w+.-]*)://([^/?#]+)([^?#]*)")
	scheme = scheme and scheme:lower()
	if scheme ~= "http" and scheme ~= "https" and scheme ~= "ssh" and scheme ~= "git" then
		return nil, "Expected an http(s) URL or Git remote"
	end
	local host = authority:match("@(.+)$") or authority
	if scheme == "ssh" then
		host = host:gsub(":%d+$", "")
	end
	return normalized(host, path, scheme == "ssh" or scheme == "git" or path:match("%.git/*$") ~= nil)
end

---@param provider AtlasProviderId
---@return AtlasParsedUrl|nil
function M.configured_base(provider)
	local base_url = (config.provider_options(provider) or {}).base_url
	if type(base_url) ~= "string" then
		return nil
	end
	return M.parse(base_url)
end

---@param parsed AtlasParsedUrl
---@param base AtlasParsedUrl|nil
---@return string|nil
function M.relative_path(parsed, base)
	if base == nil or parsed.host ~= base.host then
		return nil
	end
	if base.path == "" then
		return parsed.path
	end
	if parsed.path == base.path then
		return ""
	end
	if parsed.path:sub(1, #base.path + 1) == base.path .. "/" then
		return parsed.path:sub(#base.path + 1)
	end
	return nil
end

---@param tail string|nil
---@return boolean
function M.valid_tail(tail)
	return tail == nil or tail == "" or tail:sub(1, 1) == "/"
end

---@param provider AtlasProviderId
---@param host string
---@return string
function M.base_url(provider, host)
	local configured = (config.provider_options(provider) or {}).base_url
	configured = type(configured) == "string" and configured:gsub("/+$", "") or ""
	return configured ~= "" and configured or "https://" .. host
end

return M
