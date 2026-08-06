local M = {}

local GLYPH = {
	["+1"] = "",
	["-1"] = "",
	thumbsup = "",
	thumbsdown = "",
	laugh = "",
	laughing = "",
	hooray = "󱁖",
	tada = "󱁖",
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

---@param reactions table<string, integer>|nil
---@param options PullsReactionOption[]|nil
---@return string text, table[] spans
function M.format(reactions, options)
	if reactions == nil then
		return "", {}
	end

	local emoji_by_key, order = {}, {}
	for _, option in ipairs(options or {}) do
		emoji_by_key[option.key] = option.emoji
		table.insert(order, option.key)
	end
	for key in pairs(reactions) do
		if emoji_by_key[key] == nil then
			emoji_by_key[key] = M.glyph(key)
			table.insert(order, key)
		end
	end

	local parts, spans = {}, {}
	local col = 0
	for _, key in ipairs(order) do
		local count = tonumber(reactions[key]) or 0
		if count > 0 then
			if #parts > 0 then
				col = col + 2
			end
			local icon = emoji_by_key[key]
			local count_text = " " .. tostring(count)
			table.insert(spans, { start_col = col, end_col = col + #icon, hl_group = "AtlasLogInfo" })
			table.insert(
				spans,
				{ start_col = col + #icon, end_col = col + #icon + #count_text, hl_group = "AtlasTextMuted" }
			)
			col = col + #icon + #count_text
			table.insert(parts, icon .. count_text)
		end
	end
	return table.concat(parts, "  "), spans
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
