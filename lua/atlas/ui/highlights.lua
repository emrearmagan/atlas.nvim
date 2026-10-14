local M = {}

local dynamic_palette = {
	"#91d7e3",
	"#7dc4e4",
	"#8bd5ca",
	"#eed49f",
	"#f5a97f",
	"#f5bde6",
	"#c6a0f6",
	"#8aadf4",
	"#b7bdf8",
	"#f0c6c6",
	"#f4dbd6",
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

---Choose a foreground for a solid chip background.
---@param bg string|integer|nil
---@return string|nil
function M.foreground_for(bg)
	local color = normalize_color(bg)
	if color == nil then
		return nil
	end
	local r = tonumber(color:sub(2, 3), 16)
	local g = tonumber(color:sub(4, 5), 16)
	local b = tonumber(color:sub(6, 7), 16)
	local brightness = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	return brightness > 0.6 and "#1e1e2e" or "#ffffff"
end

---@param bg string
---@return table
local function chip_defaults(bg)
	return { bg = bg, fg = M.foreground_for(bg), bold = true }
end

---Read theme colors during setup so a colorscheme change uses fresh defaults.
---@return table<string, table>
local function default_groups()
	local function theme(group)
		return vim.api.nvim_get_hl(0, { name = group, link = false, create = false })
	end

	return {
		-- Shared UI
		AtlasCodeBackground = { bg = vim.o.background == "dark" and "#20242d" or "#f1f2f4" },
		AtlasTabInactive = { link = "CursorLine" },
		AtlasColumnHeader = { fg = "#7f849c", bold = true },
		AtlasSectionHeader = { fg = "#7f849c", bold = true, underline = true },
		AtlasBorder = { fg = theme("FloatBorder").fg },
		AtlasTextMuted = { fg = "#7f849c" },
		AtlasTextMutedStrikethrough = { fg = "#7f849c", strikethrough = true },
		AtlasTextPositive = { fg = theme("DiagnosticOk").fg, italic = false },
		AtlasTextNote = { fg = "#f5bde6", bold = true },
		AtlasTextWarning = { fg = "#f9e2af", bold = true },

		-- Provider themes
		AtlasAzureTheme = { bg = "#00AEEF", fg = "#ffffff", bold = true },
		AtlasGitHubTheme = { bg = "#1f2328", fg = "#f0f6fc", bold = true },
		AtlasGitLabTheme = { fg = "#1e1e2e", bg = "#fc6d26", bold = true },
		AtlasBitbucketTheme = { bg = "#1e3a8a", bold = true },
		AtlasJiraTheme = chip_defaults("#1e3a8a"),

		-- Chips
		AtlasChipActive = chip_defaults("#89b4fa"),
		AtlasRelatedChip = chip_defaults("#202635"),

		-- Issues and Jira fields
		AtlasIssueOpen = { fg = "#a6e3a1", bold = true },
		AtlasIssueClosed = { fg = "#a371f7", bold = true },
		AtlasIssueOpenChip = chip_defaults("#a6e3a1"),
		AtlasIssueClosedChip = chip_defaults("#a371f7"),
		AtlasJiraKey = { fg = "#89b4fa", bold = true },
		AtlasJiraEpic = { link = "AtlasLogWarn" },
		AtlasJiraChipStoryPoints = chip_defaults("#f38ba8"),
		AtlasJiraChipDueDate = chip_defaults("#313244"),
		AtlasJiraChipParent = { link = "AtlasJiraTheme" },

		-- Pull requests
		AtlasPROpen = { fg = "#86efac" },
		AtlasPRMerged = { fg = "#93c5fd" },
		AtlasPRDeclined = { fg = "#fca5a5" },
		AtlasPRDraft = { fg = "#fcd34d" },
		AtlasPROpenChip = chip_defaults("#86efac"),
		AtlasPRMergedChip = chip_defaults("#93c5fd"),
		AtlasPRDeclinedChip = chip_defaults("#fca5a5"),
		AtlasPRDraftChip = chip_defaults("#fcd34d"),

		-- Logs
		AtlasLogInfo = { fg = "#89b4fa", italic = false },
		AtlasLogWarn = { fg = theme("DiagnosticWarn").fg, italic = false },
		AtlasLogError = { fg = theme("DiagnosticError").fg, italic = false },
		AtlasLogErrorLine = {
			fg = theme("DiagnosticVirtualTextError").fg,
			bg = theme("DiagnosticVirtualTextError").bg,
			italic = false,
		},
		AtlasLogGroup = { fg = "#cdd6f4", bg = "#313244", bold = true },
		AtlasLogCommand = { fg = "#89b4fa" },
		AtlasLogDebug = { link = "AtlasTextMuted" },

		-- Footer
		AtlasFooterBackground = { bg = "#202635" },
		AtlasFooterText = { fg = "#7f849c", bg = "#202635" },
		AtlasFooterActive = { fg = "#cdd6f4", bg = "#202635", bold = true },
		AtlasFooterInfo = { fg = "#89b4fa", bg = "#202635", bold = true },
		AtlasFooterNote = { fg = "#f5bde6", bg = "#202635", bold = true },
		AtlasFooterWarning = { fg = "#f9e2af", bg = "#202635", bold = true },
		AtlasFooterError = { fg = "#f38ba8", bg = "#202635", bold = true },
		AtlasFooterSuccess = { fg = "#a6da95", bg = "#202635", bold = true },
	}
end

local generated = {}
local derived = {}

local function set_default(name, opts)
	vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", opts, { default = true }))
end

local function resolved(group)
	return vim.api.nvim_get_hl(0, { name = group, link = false, create = false })
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
	local fg = normalize_color(opts.fg) or M.foreground_for(color)
	local name = "AtlasChip_" .. color:sub(2) .. "_" .. fg:sub(2)
	generated[name] = { bg = color, fg = fg, bold = true }
	set_default(name, generated[name])
	return name
end

---@param text string
---@return integer
local function palette_index(text)
	local hash = 0
	for i = 1, #text do
		hash = (hash * 31 + string.byte(text, i)) % 2147483647
	end
	return (hash % #dynamic_palette) + 1
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
	for name, opts in pairs(default_groups()) do
		set_default(name, opts)
	end
	for idx, color in ipairs(dynamic_palette) do
		set_default(string.format("AtlasDynColor%02d", idx), { fg = color })
		set_default(string.format("AtlasDynBgColor%02d", idx), { bg = color, fg = M.foreground_for(color) })
	end
	require("atlas.formats.markdown.highlights").setup()

	-- Recreate stable names so highlights already used by open views survive a colorscheme change.
	for name, opts in pairs(generated) do
		set_default(name, opts)
	end
	for group, name in pairs(derived) do
		refresh_derived(group, name, resolved(group))
	end
end

return M
