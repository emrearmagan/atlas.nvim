local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@class RepositoryReleaseSelection
---@field release AtlasRepositoryReleaseDetails
---@field asset AtlasRepositoryReleaseAsset|nil

---@param value string|nil
---@return string
local function single_line(value)
	return vim.trim((value or ""):gsub("[\r\n]+", " "))
end

---@param release AtlasRepositoryReleaseDetails
---@return string[], table<integer, RepositoryReleaseSelection>, AtlasUIHighlight[]
function M.render(release)
	local lines, line_map, spans = {}, {}, {}
	local name = single_line(release.name)
	local heading = "# " .. (name ~= "" and name or single_line(release.tag))
	local title_end = #heading
	local badges = {}
	if release.draft then
		badges[#badges + 1] = { text = "Draft", hl = "AtlasTextWarning" }
	end
	if release.prerelease then
		badges[#badges + 1] = { text = "Prerelease", hl = "AtlasTextNote" }
	end
	for _, badge in ipairs(badges) do
		local start = #heading + 2
		heading = heading .. "  [" .. badge.text .. "]"
		spans[#spans + 1] = {
			line = 0,
			start_col = start,
			end_col = #heading,
			hl_group = badge.hl,
		}
	end
	lines[#lines + 1] = heading
	spans[#spans + 1] = { line = 0, start_col = 0, end_col = title_end, hl_group = "AtlasColumnHeader" }
	lines[#lines + 1] = ""

	local parts = {}
	local date = utils.format_date(release.published_at)
	if date ~= "" then
		parts[#parts + 1] = date
	end
	local tag = single_line(release.tag)
	if tag ~= "" then
		parts[#parts + 1] = icons.pulls("tag") .. " " .. tag
	end
	local author = single_line(release.author)
	if author ~= "" then
		parts[#parts + 1] = "by " .. author
	end
	if #parts > 0 then
		utils.push(lines, spans, table.concat(parts, "  ·  "), "AtlasTextMuted")
	end
	lines[#lines + 1] = ""
	if vim.trim(release.description) ~= "" then
		vim.list_extend(lines, utils.sanitize_lines(release.description))
	else
		utils.push(lines, spans, "No release notes.", "AtlasTextMuted")
	end
	if #release.assets > 0 then
		lines[#lines + 1] = ""
		utils.push(lines, spans, "## Assets (" .. #release.assets .. ")", "AtlasColumnHeader")
		lines[#lines + 1] = ""
		for _, asset in ipairs(release.assets) do
			local asset_name = single_line(asset.name):gsub("([\\%[%]])", "\\%1")
			local line = string.format("- [%s](%s)", asset_name, single_line(asset.url))
			local details = {}
			if asset.size ~= nil then
				details[#details + 1] = utils.human_size(asset.size)
			end
			if asset.downloads ~= nil then
				details[#details + 1] =
					string.format("%d %s", asset.downloads, asset.downloads == 1 and "download" or "downloads")
			end
			lines[#lines + 1] = line .. (#details > 0 and "  ·  " .. table.concat(details, "  ·  ") or "")
			line_map[#lines] = { release = release, asset = asset }
		end
	end
	for line = 1, #lines do
		line_map[line] = line_map[line] or { release = release }
	end
	return lines, line_map, spans
end

return M
