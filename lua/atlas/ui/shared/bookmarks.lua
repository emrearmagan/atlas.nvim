local M = {}

local config = require("atlas.config")
local icons = require("atlas.ui.shared.icons")
local providers = require("atlas.providers")
local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

---@param domain "pulls"|"issues"
---@param provider string
---@return string
function M.key(domain, provider)
	local options = config.domain_options(provider, domain) or {}
	local configured = options.bookmarks and options.bookmarks.key
	local provider_domain = providers.domain(provider, domain)
	return configured or (provider_domain and provider_domain.bookmark_key) or "S"
end

---@param items table<string, any>
---@return { name: string, value: any }[]
local function sorted_items(items)
	local out = {}
	for name, value in pairs(items) do
		table.insert(out, { name = tostring(name), value = value })
	end
	table.sort(out, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return out
end

---@generic V
---@param provider AtlasProviderId
---@param domain "pulls"|"issues"
---@param base_views V[]
---@param saved_items AtlasStarredItem[]
---@return V[]
function M.views(provider, domain, base_views, saved_items)
	local options = config.domain_options(provider, domain) or {}
	local bookmarks = options.bookmarks
	if (bookmarks == nil or next(bookmarks.items or {}) == nil) and #saved_items == 0 then
		return base_views
	end

	local provider_domain = providers.domain(provider, domain)
	local out = vim.list_extend({}, base_views)
	table.insert(out, {
		name = tostring(
			(bookmarks and bookmarks.label) or (provider_domain and provider_domain.bookmark_label) or "Search"
		),
		key = tostring(M.key(domain, provider)),
		layout = domain == "pulls" and "grouped" or "plain",
		_kind = "bookmarks",
		_bookmarks = (bookmarks and bookmarks.items) or {},
		_starred = { domain = domain, provider = provider },
	})
	return out
end

---@param value any
---@return string
local function preview_text(value)
	if type(value) == "string" then
		return value
	end
	if type(value) ~= "table" then
		return ""
	end
	local configured_targets = value.targets or value.repos
	if configured_targets then
		local targets = {}
		for _, target in ipairs(configured_targets) do
			local prefix = target.project and "project:" or ""
			local name = target.project or target.repo
			table.insert(targets, string.format("%s%s/%s", prefix, target.workspace, name))
		end
		return table.concat(targets, ", ")
	end

	local keys = {}
	for k in pairs(value) do
		if type(value[k]) ~= "table" then
			table.insert(keys, tostring(k))
		end
	end
	table.sort(keys)

	local parts = {}
	for _, k in ipairs(keys) do
		local v = value[k]
		if v ~= nil and v ~= "" then
			table.insert(parts, k .. ":" .. tostring(v))
		end
	end
	for _, v in pairs(value) do
		if type(v) == "table" then
			for ek, ev in pairs(v) do
				table.insert(parts, tostring(ek) .. "=" .. tostring(ev))
			end
		end
	end
	return table.concat(parts, " ")
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param items_table table<string, any>
---@param width integer
---@param starred { domain: "pulls"|"issues", provider: string }|nil
---@param saved_items AtlasStarredItem[]
function M.render(lines, spans, line_map, items_table, width, starred, saved_items)
	local items = sorted_items(items_table)
	if starred then
		if #saved_items > 0 then
			table.insert(items, 1, {
				name = "Starred",
				value = { _kind = "starred" },
				preview = string.format("%d item%s", #saved_items, #saved_items == 1 and "" or "s"),
			})
		end
	end
	local bookmark = icons.general("star")
	local arrow = icons.general("arrow_right") or "▸"

	local header = string.format(" %s  Bookmarks", bookmark)
	table.insert(lines, header)
	local hl_end = 1 + #bookmark
	table.insert(spans, { line = #lines - 1, start_col = 1, end_col = hl_end, hl_group = "AtlasLogInfo" })
	table.insert(spans, { line = #lines - 1, start_col = hl_end, end_col = #header, hl_group = "AtlasTextMuted" })

	if #items == 0 then
		local msg = " No bookmarks configured."
		table.insert(lines, msg)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #msg, hl_group = "AtlasTextMuted" })
		return
	end

	local left_indent = 1
	local gap = 4
	local arrow_w = ui_utils.text_width(arrow)
	local name_w = 0
	for _, item in ipairs(items) do
		local w = ui_utils.text_width(item.name)
		if w > name_w then
			name_w = w
		end
	end
	local prefix_w = left_indent + arrow_w + 2 + name_w + gap
	local preview_w = math.max(width - prefix_w - left_indent, 10)

	for _, item in ipairs(items) do
		local item_w = ui_utils.text_width(item.name)
		local name_pad = string.rep(" ", math.max(name_w - item_w, 0))
		local preview = item.preview or preview_text(item.value)
		preview = utils.truncate(preview, preview_w, false)

		local row = string.format(" %s  %s%s%s%s", arrow, item.name, name_pad, string.rep(" ", gap), preview)
		table.insert(lines, row)

		local lnum = #lines - 1
		local arrow_start = left_indent
		local arrow_end = arrow_start + #arrow
		table.insert(spans, { line = lnum, start_col = arrow_start, end_col = arrow_end, hl_group = "AtlasTextMuted" })

		if preview ~= "" then
			local preview_start = prefix_w
			table.insert(spans, { line = lnum, start_col = preview_start, end_col = #row, hl_group = "AtlasTextMuted" })
		end

		line_map[#lines] = { kind = "bookmark", name = item.name, value = item.value }
	end
end

return M
