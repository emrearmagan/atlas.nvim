local M = {}

local presentation = require("atlas.pulls.ui.presentation")
local highlights = require("atlas.ui.highlights")

---@param key string
---@param names string[]
---@param empty string
---@return AtlasFormMetaField
function M.people(key, names, empty)
	local field = { key = key, value = empty, hl = "AtlasTextMuted" }
	if #names == 0 then
		return field
	end

	field.value = ""
	field.spans = {}
	for i, name in ipairs(names) do
		if i > 1 then
			field.value = field.value .. ", "
		end
		local handle = name:gsub("^@", "")
		table.insert(field.spans, {
			start_col = #field.value,
			end_col = #field.value + #name,
			hl_group = presentation.author_hl(handle),
		})
		field.value = field.value .. name
	end
	return field
end

---@param labels (PullsLabel|GitLabPullsLabel)[]
---@return AtlasFormMetaField
function M.labels(labels)
	local field = { key = "Labels:", value = "None", hl = "AtlasTextMuted" }
	if #labels == 0 then
		return field
	end

	field.value = ""
	field.spans = {}
	for i, label in ipairs(labels) do
		if i > 1 then
			field.value = field.value .. " "
		end

		local text = " " .. label.name .. " "
		local hl = highlights.chip(label.color, { fg = label.text_color })

		table.insert(field.spans, { start_col = #field.value, end_col = #field.value + #text, hl_group = hl })
		field.value = field.value .. text
	end
	return field
end

return M
