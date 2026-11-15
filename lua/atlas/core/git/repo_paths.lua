local M = {}

local LUA_PATTERN_SPECIALS = "[%^%$%(%)%%%.%[%]%+%-%?]"

local function star_count(s)
	local _, n = s:gsub("%*", "")
	return n
end

-- Split "group/subgroup/repo" -> namespace, repo.
local function split_key(key)
	if key:sub(1, 1) == "/" or key:find("//", 1, true) then
		return nil
	end
	return key:match("^(.+)/([^/]+)$")
end

local function normalize_path(path)
	if path:sub(1, 2) == "~/" then
		path = (vim.env.HOME or vim.fn.expand("~")) .. path:sub(2)
	end
	return vim.fn.fnamemodify(path, ":p")
end

-- Turn a seg like "proj-*-v*" into a Lua pattern with one capture per `*`.
local function seg_to_pattern(seg)
	local escaped = seg:gsub(LUA_PATTERN_SPECIALS, "%%%0"):gsub("%*", "([^/]+)")
	return "^" .. escaped .. "$"
end

-- Replace each `*` in `value` with the next capture from `captures`.
local function apply_captures(value, captures)
	local idx = 0
	return (value:gsub("%*", function()
		idx = idx + 1
		return captures[idx] or ""
	end))
end

-- Pattern specificity: fewer `*` wins, then longer literal text, then alphabetical key.
local function more_specific(a, b)
	if a.stars ~= b.stars then
		return a.stars < b.stars
	end
	if a.lit ~= b.lit then
		return a.lit > b.lit
	end
	return a.key < b.key
end

---@param repo_paths table<string, string>|nil
---@return boolean ok
---@return string|nil err
local function validate(repo_paths)
	if repo_paths == nil then
		return true, nil
	end
	if type(repo_paths) ~= "table" then
		return false, "repo_paths must be a table<string,string>"
	end

	for key, value in pairs(repo_paths) do
		if type(key) ~= "string" or type(value) ~= "string" then
			return false, "repo_paths keys and values must be strings"
		end
		local _, seg = split_key(key)
		if seg == nil then
			return false, string.format("invalid key '%s' (expected namespace/repo or namespace/<pattern with *>)", key)
		end
		if star_count(seg) ~= star_count(value) then
			return false, string.format("wildcard parity mismatch for '%s' → '%s'", key, value)
		end
	end

	return true, nil
end

---@param repo_paths table<string, string> `pulls.repo_config.paths`
---@param repo_name string
---@return string|nil path
---@return string|nil err
function M.resolve(repo_paths, repo_name)
	local ok, err = validate(repo_paths)
	if not ok then
		return nil, err
	end

	local namespace, repo = split_key(repo_name)
	if not namespace then
		return nil, "invalid repository identifier (expected namespace/repo)"
	end

	-- Exact match wins over any wildcard.
	---@type string|nil
	local resolved = repo_paths[repo_name]
	if not resolved or resolved == "" then
		local best
		for key, value in pairs(repo_paths) do
			local key_namespace, seg = split_key(key)
			if key_namespace == namespace and seg:find("*", 1, true) and value ~= "" then
				local captures = { repo:match(seg_to_pattern(seg)) }
				if captures[1] then
					local stars = star_count(seg)
					local candidate = {
						key = key,
						stars = stars,
						lit = #seg - stars,
						value = apply_captures(value, captures),
					}
					if not best or more_specific(candidate, best) then
						best = candidate
					end
				end
			end
		end
		resolved = best and best.value or nil
	end

	if not resolved or resolved == "" then
		return nil, string.format("no repo_paths mapping for '%s'", repo_name)
	end
	return normalize_path(resolved), nil
end

return M
