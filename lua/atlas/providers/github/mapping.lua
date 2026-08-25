local M = {}

local json = require("atlas.core.json")

local REACTION_KEY = {
	THUMBS_UP = "+1",
	THUMBS_DOWN = "-1",
	LAUGH = "laugh",
	HOORAY = "hooray",
	CONFUSED = "confused",
	HEART = "heart",
	ROCKET = "rocket",
	EYES = "eyes",
}

local REACTION_KEYS = {
	["+1"] = true,
	["-1"] = true,
	laugh = true,
	hooray = true,
	confused = true,
	heart = true,
	rocket = true,
	eyes = true,
}

---@param raw any
---@return { id: string, login: string, name: string }|nil
function M.identity(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local login = json.safe_str(raw.login) or ""
	local name = json.safe_str(raw.name) or ""
	return {
		id = json.safe_str(raw.id) or json.safe_str(raw.databaseId) or "",
		login = login,
		name = name ~= "" and name or login,
	}
end

---@param groups any
---@return table<string, integer>|nil
function M.reaction_groups(groups)
	local reactions
	for _, group in ipairs(json.safe_table(groups)) do
		group = json.safe_table(group)
		local users = json.safe_table(json.nilify(group.reactors) or json.nilify(group.users))
		local count = tonumber(users.totalCount) or 0
		local name = REACTION_KEY[json.safe_str(group.content) or ""]
		if name and count > 0 then
			reactions = reactions or {}
			reactions[name] = (reactions[name] or 0) + count
		end
	end
	return reactions
end

---@param raw any
---@return table<string, integer>|nil
function M.reaction_counts(raw)
	local reactions
	for key, count in pairs(json.safe_table(raw)) do
		local name = tostring(key)
		local normalized_count = tonumber(count) or 0
		if REACTION_KEYS[name] and normalized_count > 0 then
			reactions = reactions or {}
			reactions[name] = normalized_count
		end
	end
	return reactions
end

---@param raw any
---@param fallback string|nil
---@return string owner, string repo, string full_name
function M.repository(raw, fallback)
	local full_name = ""
	local name = ""
	raw = json.safe_table(raw)
	full_name = json.safe_str(raw.nameWithOwner) or json.safe_str(raw.full_name) or ""
	name = json.safe_str(raw.name) or ""
	if full_name == "" then
		local owner = json.safe_str(json.safe_table(raw.owner).login) or ""
		if owner ~= "" and name ~= "" then
			full_name = owner .. "/" .. name
		end
	end
	if full_name == "" then
		full_name = tostring(fallback or "")
	end
	local owner, repo = full_name:match("^(.*)/([^/]+)$")
	return owner or "", name ~= "" and name or repo or full_name, full_name
end

---@param value any
---@return table
function M.connection_nodes(value)
	value = json.safe_table(value)
	if json.nilify(value.nodes) ~= nil then
		return json.safe_table(value.nodes)
	end
	return value
end

return M
