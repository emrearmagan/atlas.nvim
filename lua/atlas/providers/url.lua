local M = {}

local config = require("atlas.config")

---@class AtlasParsedUrl
---@field host string
---@field path string
---@field remote boolean

---@param value string
---@return AtlasParsedUrl|nil, string|nil
function M.parse(value)
	if value == "" then
		return nil, "Missing URL"
	end

	local host, path = value:match("^[^/@:]+@([^/:]+):(.+)$")
	local remote = host ~= nil
	if remote then
		path = "/" .. path:gsub("^/+", "")
	else
		local scheme, authority
		scheme, authority, path = value:match("^([%a][%w+.-]*)://([^/?#]+)([^?#]*)")
		scheme = scheme and scheme:lower() or nil
		if scheme ~= "http" and scheme ~= "https" and scheme ~= "ssh" and scheme ~= "git" then
			return nil, "Expected an http(s) URL or Git remote"
		end
		host = authority:match("@(.+)$") or authority
		remote = scheme == "ssh" or scheme == "git" or path:match("%.git/*$") ~= nil
	end

	path = (path or "")
		:gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end)
		:gsub("/+$", "")
	return { host = host:lower(), path = path, remote = remote }
end

---@param provider AtlasProviderId
---@return AtlasParsedUrl|nil
function M.configured_base(provider)
	local options = config.provider_options(provider)
	local base_url = type(options) == "table" and options.base_url or nil
	if type(base_url) ~= "string" then
		return nil
	end
	return M.parse(base_url)
end

---@param parsed AtlasParsedUrl
---@param base AtlasParsedUrl|nil
---@return string|nil
function M.path(parsed, base)
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
---@param target_host string|nil
---@param fallback_host string|nil
---@return string
function M.base_url(provider, target_host, fallback_host)
	local options = config.provider_options(provider) or {}
	local configured = type(options.base_url) == "string" and options.base_url:gsub("/+$", "") or nil
	if configured and configured ~= "" then
		return configured
	end
	return "https://" .. (target_host and target_host ~= "" and target_host or fallback_host or "")
end

return M
