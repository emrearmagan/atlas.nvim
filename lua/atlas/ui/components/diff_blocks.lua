local M = {}

local FILLED = "■"
local EMPTY = "□"
local BLOCK_COUNT = 5

---@class DiffBlocksOpts
---@field additions number
---@field deletions number
---@field add_hl? string
---@field del_hl? string
---@field empty_hl? string
---@field add_text_hl? string
---@field del_text_hl? string
---@field show_count? boolean    -- show "+N -N" after the blocks (default true)

---@class DiffBlocksResult
---@field text string
---@field highlights table[]

---@param opts DiffBlocksOpts
---@return DiffBlocksResult
function M.render(opts)
	local add = tonumber(opts.additions) or 0
	local del = tonumber(opts.deletions) or 0
	local total = add + del

	if total == 0 then
		return { text = "", highlights = {} }
	end

	local add_hl = opts.add_hl or "AtlasTextPositive"
	local del_hl = opts.del_hl or "AtlasLogError"
	local empty_hl = opts.empty_hl or "AtlasTextMuted"
	local add_text_hl = opts.add_text_hl or add_hl
	local del_text_hl = opts.del_text_hl or del_hl

	local max_filled = math.min(BLOCK_COUNT, total)
	local green_count = math.floor(add / total * max_filled)
	local red_count = math.floor(del / total * max_filled)
	local grey_count = BLOCK_COUNT - green_count - red_count

	local blocks = string.rep(FILLED, green_count + red_count) .. string.rep(EMPTY, grey_count)
	local show_count = opts.show_count ~= false

	local p_green = green_count * #FILLED
	local p_red = (green_count + red_count) * #FILLED
	local p_blocks = p_red + grey_count * #EMPTY

	local highlights = {}
	if p_green > 0 then
		highlights[#highlights + 1] = { start_col = 0, end_col = p_green, hl_group = add_hl }
	end
	if p_red > p_green then
		highlights[#highlights + 1] = { start_col = p_green, end_col = p_red, hl_group = del_hl }
	end
	if p_blocks > p_red then
		highlights[#highlights + 1] = { start_col = p_red, end_col = p_blocks, hl_group = empty_hl }
	end

	if not show_count then
		return { text = blocks, highlights = highlights }
	end

	local add_str = "+" .. tostring(add)
	local del_str = "-" .. tostring(del)
	local text = blocks .. " " .. add_str .. " " .. del_str

	local p_add_s = p_blocks + 1
	local p_add_e = p_add_s + #add_str
	local p_del_s = p_add_e + 1
	local p_del_e = p_del_s + #del_str

	highlights[#highlights + 1] = { start_col = p_add_s, end_col = p_add_e, hl_group = add_text_hl }
	highlights[#highlights + 1] = { start_col = p_del_s, end_col = p_del_e, hl_group = del_text_hl }

	return { text = text, highlights = highlights }
end

return M
