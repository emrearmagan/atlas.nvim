local M = {}

M.groups = {
	strong = "AtlasMarkdownStrong",
	em = "AtlasMarkdownEmphasis",
	strike = "AtlasMarkdownStrike",
	link = "AtlasMarkdownLink",
	image = "AtlasMarkdownImage",
	inline_code = "AtlasMarkdownInlineCode",
	comment = "AtlasMarkdownComment",

	heading_1 = "AtlasMarkdownHeading1",
	heading_2 = "AtlasMarkdownHeading2",
	heading_3 = "AtlasMarkdownHeading3",
	heading_4 = "AtlasMarkdownHeading4",
	heading_5 = "AtlasMarkdownHeading5",
	heading_6 = "AtlasMarkdownHeading6",

	list_marker = "AtlasMarkdownList",
	task_done = "AtlasMarkdownTaskDone",
	task_todo = "AtlasMarkdownTaskTodo",

	quote = "AtlasMarkdownQuote",
	quote_bar = "AtlasMarkdownQuoteBar",
	rule = "AtlasMarkdownRule",

	code = "AtlasMarkdownCode",
	code_lang = "AtlasMarkdownCodeLabel",

	panel_info = "AtlasMarkdownNote",
	panel_success = "AtlasMarkdownTip",
	panel_important = "AtlasMarkdownImportant",
	panel_warning = "AtlasMarkdownWarning",
	panel_error = "AtlasMarkdownCaution",

	table_header = "AtlasMarkdownTableHeader",
	table_row = "AtlasMarkdownTableRow",
	table_border = "AtlasMarkdownTableBorder",
}

local function foreground(group)
	return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
end

function M.setup()
	local dark = vim.o.background == "dark"
	local inline_bg = dark and "#2b2d3a" or "#e3e5e8"
	local blue = foreground("Function")
	local muted = foreground("Comment")

	local groups = {
		AtlasMarkdownStrong = { bold = true },
		AtlasMarkdownEmphasis = { italic = true },
		AtlasMarkdownStrike = { fg = muted, strikethrough = true },
		AtlasMarkdownLink = { fg = blue, underline = true },
		AtlasMarkdownImage = { fg = muted },
		AtlasMarkdownInlineCode = { fg = foreground("Constant"), bg = inline_bg },
		AtlasMarkdownComment = { link = "Comment" },

		AtlasMarkdownHeading1 = { link = "Title" },
		AtlasMarkdownHeading2 = { fg = foreground("Statement"), bold = true },
		AtlasMarkdownHeading3 = { fg = foreground("String"), bold = true },
		AtlasMarkdownHeading4 = { fg = foreground("Type"), bold = true },
		AtlasMarkdownHeading5 = { fg = foreground("Constant"), bold = true, italic = true },
		AtlasMarkdownHeading6 = { fg = foreground("Special"), italic = true },

		AtlasMarkdownList = { fg = blue, bold = true },
		AtlasMarkdownTaskDone = { fg = foreground("DiagnosticOk") },
		AtlasMarkdownTaskTodo = { fg = muted },

		AtlasMarkdownQuote = { fg = muted, italic = true },
		AtlasMarkdownQuoteBar = { link = "Comment" },
		AtlasMarkdownRule = { link = "NonText" },

		AtlasMarkdownCode = { link = "AtlasCodeBackground" },
		AtlasMarkdownCodeLabel = { fg = muted, italic = true },

		AtlasMarkdownNote = { fg = foreground("DiagnosticInfo"), bold = true },
		AtlasMarkdownTip = { fg = foreground("DiagnosticOk"), bold = true },
		AtlasMarkdownImportant = { fg = foreground("Statement"), bold = true },
		AtlasMarkdownWarning = { fg = foreground("DiagnosticWarn"), bold = true },
		AtlasMarkdownCaution = { fg = foreground("DiagnosticError"), bold = true },

		AtlasMarkdownTableHeader = { fg = blue, bold = true },
		AtlasMarkdownTableRow = { link = "AtlasCodeBackground" },
		AtlasMarkdownTableBorder = { link = "NonText" },
	}

	for name, opts in pairs(groups) do
		opts.default = true
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
