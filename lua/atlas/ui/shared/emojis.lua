local M = {}

local GLYPH = {
	["+1"] = "",
	["-1"] = "",
	laugh = "",
	hooray = "󱁖",
	confused = "󱃞",
	heart = "",
	rocket = "",
	eyes = "",
	fallback = "󰼇",
}

local ORDER = { "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes" }

---@param key string
---@return string
function M.glyph(key)
	return GLYPH[key] or GLYPH.fallback
end

---@param key_for fun(atlas_key: string): string
---@return PullsReactionOption[]
local function build(key_for)
	local out = {}
	for _, k in ipairs(ORDER) do
		local key = key_for(k)
		table.insert(out, { key = key, emoji = GLYPH[k] or GLYPH.fallback, label = key })
	end
	return out
end

---@return PullsReactionOption[]
function M.github()
	return build(function(k)
		return k
	end)
end

---@return PullsReactionOption[]
function M.gitlab()
	-- Atlas key -> GitLab API name
	local name = {
		["+1"] = "thumbsup",
		["-1"] = "thumbsdown",
		laugh = "laughing",
		hooray = "tada",
		confused = "confused",
		heart = "heart",
		rocket = "rocket",
		eyes = "eyes",
	}
	return build(function(k)
		return name[k] or k
	end)
end

return M
