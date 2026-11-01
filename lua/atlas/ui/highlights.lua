local M = {}

-- Atlas follows the active colorscheme. Groups read the colors of standard
-- Neovim groups so light and dark backgrounds stay readable, without taking
-- over attributes like italic. Provider brand hues are the only fixed colors.
local BRAND = {
	azure = "#00AEEF",
	gitlab = "#fc6d26",
	bitbucket = "#2684ff",
	jira = "#2684ff",
}

-- Standard groups used for stable per-author and per-status colors.
local dynamic_groups = {
	"Function",
	"Statement",
	"DiagnosticOk",
	"DiagnosticWarn",
	"DiagnosticInfo",
	"String",
	"Constant",
	"Type",
	"Identifier",
	"Special",
	"DiagnosticHint",
}

---@param color string|integer|nil
---@return string|nil
local function normalize_color(color)
	if type(color) == "number" then
		if color >= 0 and color <= 0xffffff and color % 1 == 0 then
			return string.format("#%06x", color)
		end
	elseif type(color) == "string" then
		local hex = color:gsub("^#", "")
		if hex:match("^%x%x%x%x%x%x$") then
			return "#" .. hex:lower()
		end
	end
	return nil
end

---@param color string Normalized "#rrggbb" color
---@return string
local function contrast(color)
	local r = tonumber(color:sub(2, 3), 16)
	local g = tonumber(color:sub(4, 5), 16)
	local b = tonumber(color:sub(6, 7), 16)
	local brightness = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	return brightness > 0.6 and "#000000" or "#ffffff"
end

---@param name string
---@return table
local function resolved(name)
	return vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
end

---@param name string
---@return string|nil
local function foreground(name)
	return normalize_color(resolved(name).fg)
end

---@param name string
---@return string|nil
local function background(name)
	return normalize_color(resolved(name).bg)
end

---Blend `color` into `base`.
---@param base string
---@param color string
---@param alpha number
---@return string
local function blend(base, color, alpha)
	local function channel(offset)
		local from = tonumber(base:sub(offset, offset + 1), 16)
		local to = tonumber(color:sub(offset, offset + 1), 16)
		return math.floor(from + (to - from) * alpha + 0.5)
	end

	return string.format("#%02x%02x%02x", channel(2), channel(4), channel(6))
end

---Choose a foreground for a solid chip background.
---@param bg string|integer|nil
---@return string|nil
function M.foreground_for(bg)
	local color = normalize_color(bg)
	return color and contrast(color)
end

---@param color string|nil
---@return table
local function chip_style(color)
	color = normalize_color(color)
	return { bg = color, fg = color and contrast(color) or nil, bold = true }
end

local labels = {}

---@param color string
---@return integer, integer, integer
local function channels(color)
	return tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
end

---@param color string
---@return number, number, number
local function to_hsl(color)
	local r, g, b = channels(color)
	r, g, b = r / 255, g / 255, b / 255
	local high, low = math.max(r, g, b), math.min(r, g, b)
	local l = (high + low) / 2
	if high == low then
		return 0, 0, l
	end

	local d = high - low
	local s = l > 0.5 and d / (2 - high - low) or d / (high + low)
	local h
	if high == r then
		h = (g - b) / d + (g < b and 6 or 0)
	elseif high == g then
		h = (b - r) / d + 2
	else
		h = (r - g) / d + 4
	end

	return h / 6, s, l
end

---@param p number
---@param q number
---@param t number
---@return number
local function hue_channel(p, q, t)
	t = t % 1
	if t < 1 / 6 then
		return p + (q - p) * 6 * t
	elseif t < 1 / 2 then
		return q
	elseif t < 2 / 3 then
		return p + (q - p) * (2 / 3 - t) * 6
	end

	return p
end

---@param h number
---@param s number
---@param l number
---@return string
local function from_hsl(h, s, l)
	local q = l < 0.5 and l * (1 + s) or l + s - l * s
	local p = 2 * l - q
	local r, g, b = hue_channel(p, q, h + 1 / 3), hue_channel(p, q, h), hue_channel(p, q, h - 1 / 3)
	return string.format(
		"#%02x%02x%02x",
		math.floor(r * 255 + 0.5),
		math.floor(g * 255 + 0.5),
		math.floor(b * 255 + 0.5)
	)
end

---A subtle background used for code blocks and secondary rows.
---@return string|nil
local function line_background()
	return background("Pmenu") or background("CursorLine") or background("NormalFloat")
end

---A label chip that stays readable on the current background.
---@param color string
---@return table
local function label_style(color)
	-- Transparent themes have no Normal background, so tint against the line
	-- background instead of falling back to solid chips.
	local page = background("Normal") or line_background()
	if vim.o.background == "light" or page == nil then
		return chip_style(color)
	end

	local r, g, b = channels(color)
	local perceived = (r * 0.2126 + g * 0.7152 + b * 0.0722) / 255
	local h, s, l = to_hsl(color)
	return {
		fg = from_hsl(h, s, math.min(1, l + math.max(0, 0.6 - perceived))),
		bg = blend(page, color, 0.18),
		bold = true,
	}
end

---@return string|nil
local function footer_background()
	return background("StatusLine") or line_background()
end

---Groups that map one to one onto a standard Neovim highlight. Only UI
---surfaces link; text colors copy the foreground alone so theme attributes
---like italic do not leak into Atlas.
---@return table<string, string>
local function links()
	return {
		-- Shared UI
		AtlasTabInactive = "CursorLine",

		-- Logs
		AtlasLogDebug = "AtlasTextMuted",

		-- Jira
		AtlasJiraEpic = "AtlasLogWarn",
		AtlasJiraChipParent = "AtlasJiraTheme",
	}
end

---Groups that need attributes or a background. Their colors are read from the
---active colorscheme, so they adapt to light and dark themes.
---@return table<string, table>
local function styles()
	local line = line_background()
	local footer = footer_background()
	-- Use Comment's color without its attributes so muted text stays upright.
	local muted = foreground("Comment") or foreground("NonText")
	local text = foreground("Normal") or muted
	local accent = foreground("Function") or foreground("Identifier")
	local ok = foreground("DiagnosticOk") or foreground("String")
	local info = foreground("DiagnosticInfo") or accent
	local warn = foreground("DiagnosticWarn") or foreground("Type")
	local warn_icon = foreground("Special") or info
	local err = foreground("DiagnosticError") or foreground("ErrorMsg")
	local page = background("Normal")

	local error_line = { fg = foreground("DiagnosticVirtualTextError") or err }
	if page ~= nil and error_line.fg ~= nil then
		error_line.bg = blend(page, error_line.fg, 0.15)
	end

	return {
		-- Shared UI
		AtlasCodeBackground = { bg = line },
		AtlasBorder = { fg = foreground("FloatBorder") or muted },
		AtlasColumnHeader = { fg = muted, bold = true },
		AtlasSectionHeader = { fg = muted, bold = true, underline = true },
		AtlasTextMuted = { fg = muted },
		AtlasTextMutedStrikethrough = { fg = muted, strikethrough = true },
		AtlasTextNote = { fg = warn_icon, bold = true },
		AtlasTextWarning = { fg = warn, bold = true },

		-- Provider badges
		AtlasAzureTheme = chip_style(BRAND.azure),
		AtlasGitHubTheme = { bg = line, fg = text, bold = true },
		AtlasGitLabTheme = chip_style(BRAND.gitlab),
		AtlasBitbucketTheme = chip_style(BRAND.bitbucket),
		AtlasJiraTheme = chip_style(BRAND.jira),

		-- Chips
		AtlasChipActive = chip_style(info),
		AtlasRelatedChip = { bg = line, fg = muted, bold = true },

		-- Issues and Jira fields
		AtlasIssueOpen = { fg = ok },
		AtlasIssueClosed = { fg = warn_icon, bold = true },
		AtlasIssueOpenChip = chip_style(ok),
		AtlasIssueClosedChip = chip_style(warn_icon),
		AtlasJiraKey = { fg = accent, bold = true },
		AtlasJiraChipStoryPoints = chip_style(err),
		AtlasJiraChipDueDate = { bg = line, fg = muted, bold = true },

		-- Pull requests
		AtlasPROpen = { fg = ok },
		AtlasPRMerged = { fg = info },
		AtlasPRDeclined = { fg = err },
		AtlasPRDraft = { fg = warn },
		AtlasPROpenChip = chip_style(ok),
		AtlasPRMergedChip = chip_style(info),
		AtlasPRDeclinedChip = chip_style(err),
		AtlasPRDraftChip = chip_style(warn),

		-- Text
		AtlasTextPositive = { fg = ok },

		-- Logs
		AtlasLogInfo = { fg = info },
		AtlasLogWarn = { fg = warn },
		AtlasLogError = { fg = err },
		AtlasLogCommand = { fg = accent },
		AtlasLogErrorLine = error_line,
		AtlasLogGroup = { fg = text, bg = line, bold = true },

		-- Footer
		AtlasFooterBackground = { bg = footer },
		AtlasFooterText = { fg = muted, bg = footer },
		AtlasFooterActive = { fg = text, bg = footer, bold = true },
		AtlasFooterInfo = { fg = info, bg = footer, bold = true },
		AtlasFooterNote = { fg = warn_icon, bg = footer, bold = true },
		AtlasFooterWarning = { fg = warn, bg = footer, bold = true },
		AtlasFooterError = { fg = err, bg = footer, bold = true },
		AtlasFooterSuccess = { fg = ok, bg = footer, bold = true },
	}
end

local generated = {}
local derived = {}

local function set_default(name, opts)
	vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", opts, { default = true }))
end

local function needs_foreground(opts)
	return opts.bg ~= nil and opts.fg == nil and not opts.reverse and not opts.standout and (opts.blend or 0) == 0
end

local function refresh_derived(group, name, opts)
	if needs_foreground(opts) then
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", opts, { fg = M.foreground_for(opts.bg), default = false }))
	else
		-- Existing spans must follow the source even when it no longer needs a foreground.
		vim.api.nvim_set_hl(0, name, { link = group })
	end
end

---Use a configured Jira highlight, adding a missing foreground in a separate group.
---@param group string
---@return string
function M.chip_from_group(group)
	if group == "" then
		return group
	end
	local opts = resolved(group)
	local name = derived[group]
	if needs_foreground(opts) then
		name = name or ("AtlasChipGroup_" .. group)
		derived[group] = name
		refresh_derived(group, name, opts)
		return name
	end
	if name then
		refresh_derived(group, name, opts)
	end
	return group
end

---Create a reusable label highlight, preserving a provider's explicit text color.
---Missing or invalid background colors use AtlasTextMuted.
---@param bg string|integer|nil
---@param opts { fg?: string|integer }|nil
---@return string
function M.chip(bg, opts)
	opts = opts or {}
	local color = normalize_color(bg)
	if color == nil then
		return "AtlasTextMuted"
	end
	local text = normalize_color(opts.fg) or contrast(color)
	local name = "AtlasChip_" .. color:sub(2) .. "_" .. text:sub(2)
	generated[name] = { bg = color, fg = text, bold = true }
	set_default(name, generated[name])
	return name
end

---Create a reusable label highlight from a provider-supplied label color.
---@param color string|integer|nil
---@return string
function M.label(color)
	local normalized = normalize_color(color)
	if normalized == nil then
		return "AtlasTextMuted"
	end

	local name = "AtlasLabel_" .. normalized:sub(2)
	if not labels[name] then
		labels[name] = normalized
		vim.api.nvim_set_hl(0, name, label_style(normalized))
	end

	return name
end

---@param text string
---@return integer
local function palette_index(text)
	local hash = 0
	for i = 1, #text do
		hash = (hash * 31 + string.byte(text, i)) % 2147483647
	end
	return (hash % #dynamic_groups) + 1
end

---Same identifier always maps to the same palette color.
---@param identifier string|nil
---@return string|nil
function M.dynamic_for(identifier)
	if identifier == nil or identifier == "" then
		return nil
	end
	return string.format("AtlasDynColor%02d", palette_index(identifier))
end

---@param identifier string|nil
---@return string|nil
function M.dynamic_for_bg(identifier)
	if identifier == nil or identifier == "" then
		return nil
	end
	return string.format("AtlasDynBgColor%02d", palette_index(identifier))
end

function M.setup()
	for name, target in pairs(links()) do
		set_default(name, { link = target })
	end
	for name, opts in pairs(styles()) do
		set_default(name, opts)
	end
	for index, group in ipairs(dynamic_groups) do
		set_default(string.format("AtlasDynColor%02d", index), { fg = foreground(group) })
		set_default(string.format("AtlasDynBgColor%02d", index), chip_style(foreground(group)))
	end
	require("atlas.formats.markdown.highlights").setup()

	-- Recreate stable names so highlights already used by open views survive a colorscheme change.
	for name, opts in pairs(generated) do
		set_default(name, opts)
	end
	for group, name in pairs(derived) do
		refresh_derived(group, name, resolved(group))
	end
	for name, color in pairs(labels) do
		vim.api.nvim_set_hl(0, name, label_style(color))
	end
end

return M
