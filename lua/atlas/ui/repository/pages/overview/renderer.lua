local chips = require("atlas.ui.components.chips")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param repo AtlasRepositoryDetails
---@param width integer
---@return string[], table[]
local function render_header(repo, width)
	local lines, spans = {}, {}
	utils.push(lines, spans, repo.full_name or repo.name, "AtlasColumnHeader")
	table.insert(lines, "")

	local metadata = { repo.is_private and "Private" or "Public" }
	if repo.default_branch then
		table.insert(metadata, icons.pulls("branch") .. " " .. repo.default_branch)
	end
	local created = utils.format_date(repo.created_on)
	if created ~= "" then
		table.insert(metadata, "Created " .. created)
	end
	utils.push(lines, spans, table.concat(metadata, "   "), "AtlasTextMuted")
	table.insert(lines, "")

	local stats = ""
	for _, stat in ipairs({
		{ label = "stars", count = repo.stars, icon = { icons.general("star") } },
		{ label = "forks", count = repo.forks, icon = { icons.pulls("fork") } },
		{ label = "watchers", count = repo.watchers, icon = { icons.general("watching") } },
	}) do
		if stat.count ~= nil then
			stats = stats .. (stats ~= "" and "   " or "")
			table.insert(spans, {
				line = #lines,
				start_col = #stats,
				end_col = #stats + #stat.icon[1],
				hl_group = stat.icon[2],
			})
			stats = stats .. stat.icon[1] .. " " .. stat.count .. " " .. stat.label
		end
	end
	if stats ~= "" then
		table.insert(lines, stats)
		table.insert(lines, "")
	end

	if repo.topics and #repo.topics > 0 then
		local topics = {}
		for _, topic in ipairs(repo.topics) do
			table.insert(topics, { label = topic, hl = "AtlasChipActive" })
		end
		local topic_lines, topic_spans = chips.render(topics, { width = width, padding_x = 0 })
		utils.append_block(lines, spans, { lines = topic_lines, highlights = topic_spans })
		table.insert(lines, "")
	end

	return lines, spans
end

---@param repo AtlasRepositoryDetails
---@param width integer
---@return string[], table[]
local function render_description(repo, width)
	local lines, spans = {}, {}
	if not repo.description or repo.description == "" then
		return lines, spans
	end

	utils.push(lines, spans, "Description", "AtlasColumnHeader")
	for _, line in ipairs(utils.sanitize_lines(repo.description)) do
		vim.list_extend(lines, utils.wrap_line(line, width))
	end
	table.insert(lines, "")
	return lines, spans
end

---@param repo AtlasRepositoryDetails
---@return string[], table[]
local function render_readme(repo)
	local lines, spans = {}, {}
	if not repo.readme or repo.readme == "" then
		return lines, spans
	end

	utils.push(lines, spans, "README", "AtlasColumnHeader")
	table.insert(lines, "")
	vim.list_extend(lines, utils.sanitize_lines(repo.readme))
	table.insert(lines, "")
	return lines, spans
end

---@param repo AtlasRepositoryDetails
---@param width integer
---@return string[], table[]
function M.render(repo, width)
	local lines, spans = {}, {}
	for _, render in ipairs({ render_header, render_description, render_readme }) do
		local section_lines, section_spans = render(repo, width)
		utils.append_block(lines, spans, { lines = section_lines, highlights = section_spans })
	end
	return lines, spans
end

return M
