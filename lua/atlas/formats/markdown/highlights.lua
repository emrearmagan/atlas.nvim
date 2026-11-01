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

---@param name string
---@return table
local function resolved(name)
	return vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
end

---Use the foreground of a standard group, keeping the given attributes.
---@param name string
---@param opts table
---@return table
local function styled(name, opts)
	opts.fg = resolved(name).fg
	return opts
end

function M.setup()
	local groups = {
		AtlasMarkdownStrong = { bold = true },
		AtlasMarkdownEmphasis = { italic = true },
		AtlasMarkdownStrike = { strikethrough = true },
		AtlasMarkdownLink = styled("Function", { underline = true }),
		AtlasMarkdownImage = styled("Comment", {}),
		AtlasMarkdownInlineCode = { link = "AtlasCodeBackground" },
		AtlasMarkdownComment = { link = "Comment" },

		AtlasMarkdownHeading1 = { link = "Title" },
		AtlasMarkdownHeading2 = styled("Function", { bold = true }),
		AtlasMarkdownHeading3 = styled("String", { bold = true }),
		AtlasMarkdownHeading4 = styled("Type", { bold = true }),
		AtlasMarkdownHeading5 = styled("Constant", { bold = true, italic = true }),
		AtlasMarkdownHeading6 = styled("Special", { italic = true }),

		AtlasMarkdownList = styled("Function", { bold = true }),
		AtlasMarkdownTaskDone = { link = "DiagnosticOk" },
		AtlasMarkdownTaskTodo = styled("Comment", {}),

		AtlasMarkdownQuote = styled("Comment", { italic = true }),
		AtlasMarkdownQuoteBar = { link = "Comment" },
		AtlasMarkdownRule = { link = "NonText" },

		AtlasMarkdownCode = { link = "AtlasCodeBackground" },
		AtlasMarkdownCodeLabel = styled("Comment", { italic = true }),

		AtlasMarkdownNote = styled("DiagnosticInfo", { bold = true }),
		AtlasMarkdownTip = styled("DiagnosticOk", { bold = true }),
		AtlasMarkdownImportant = styled("Statement", { bold = true }),
		AtlasMarkdownWarning = styled("DiagnosticWarn", { bold = true }),
		AtlasMarkdownCaution = styled("DiagnosticError", { bold = true }),

		AtlasMarkdownTableHeader = styled("Function", { bold = true }),
		AtlasMarkdownTableRow = { link = "AtlasCodeBackground" },
		AtlasMarkdownTableBorder = { link = "NonText" },
	}

	for name, opts in pairs(groups) do
		opts.default = true
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
