local M = {}

local GLYPHS = {
	thumbsup = "",
	thumbsdown = "",
	laughing = "",
	tada = "󱁖",
	confused = "󱃞",
	heart = "",
	rocket = "",
	eyes = "",
	smile = "",
	pray = "󰕹",
	thinking = "󰟶",
	joy = "󱈔",
	wink = "󰱸",
	ok_hand = "󰩐",
	wave = "󱠡",
	raised_hands = "󰙌",
	muscle = "󰿗",
	white_check_mark = "",
	x = "",
	warning = "",
	information_source = "",
	question = "",
	hourglass_flowing_sand = "",
	heavy_check_mark = "",
	pushpin = "",
	fire = "󰈸",
	bug = "",
	star = "",
	sparkles = "",
	clap = "󱥋",
	zap = "󱐋",
	bulb = "",
	mega = "",
	speech_balloon = "",
	ballot_box = "",
	arrow_up = "",
}

local FALLBACK = "󰼇"

---@param name string
---@return string
function M.get(name)
	return GLYPHS[name] or FALLBACK
end

---@return string[]
function M.names()
	local names = vim.tbl_keys(GLYPHS)
	table.sort(names)
	return names
end

return M
