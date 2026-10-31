describe("ui.highlights", function()
	local highlights
	local set
	local theme
	local original_get
	local original_set

	before_each(function()
		original_get, original_set = vim.api.nvim_get_hl, vim.api.nvim_set_hl
		set = {}
		theme = {
			Normal = { fg = 0x1c1e26, bg = 0xffffff },
			Comment = { fg = 0x6c6f85, italic = true },
			NonText = { fg = 0x8a8fa3 },
			CursorLine = { bg = 0xf1f2f4 },
			Pmenu = { bg = 0xeef1f8 },
			StatusLine = { fg = 0x1c1e26, bg = 0xeef1f8 },
			FloatBorder = { fg = 0x9ca0b0 },
			Function = { fg = 0x1e66f5 },
			Identifier = { fg = 0x2f7d32 },
			Statement = { fg = 0xdf8e1d },
			String = { fg = 0x40a02b },
			Constant = { fg = 0xd20f39 },
			Type = { fg = 0xdf8e1d },
			Special = { fg = 0x8839ef },
			DiagnosticOk = { fg = 0x40a02b },
			DiagnosticInfo = { fg = 0x0ea5e9 },
			DiagnosticWarn = { fg = 0xdf8e1d },
			DiagnosticError = { fg = 0xd20f39 },
			DiagnosticHint = { fg = 0x7287fd },
			DiagnosticVirtualTextError = { fg = 0xd20f39 },
		}
		vim.api.nvim_get_hl = function(_, opts)
			return vim.deepcopy(theme[opts.name] or {})
		end
		vim.api.nvim_set_hl = function(_, name, opts)
			set[name] = vim.deepcopy(opts)
		end
		package.loaded["atlas.ui.highlights"] = nil
		package.loaded["atlas.formats.markdown.highlights"] = nil
		highlights = require("atlas.ui.highlights")
	end)

	after_each(function()
		vim.api.nvim_get_hl, vim.api.nvim_set_hl = original_get, original_set
	end)

	it("links semantic groups to standard highlights", function()
		highlights.setup()

		assert.are.same({ link = "DiagnosticOk", default = true }, set.AtlasTextPositive)
		assert.are.same({ link = "DiagnosticInfo", default = true }, set.AtlasPRMerged)
		assert.are.same({ link = "AtlasTextMuted", default = true }, set.AtlasLogDebug)
		assert.are.same({ link = "AtlasCodeBackground", default = true }, set.AtlasMarkdownInlineCode)
	end)

	it("derives the remaining groups from the colorscheme", function()
		highlights.setup()

		assert.are.same({ fg = "#6c6f85", default = true }, set.AtlasTextMuted)
		assert.are.same({ fg = "#9ca0b0", default = true }, set.AtlasBorder)
		assert.are.same({ bg = "#eef1f8", default = true }, set.AtlasCodeBackground)
		assert.are.same({ bg = "#eef1f8", default = true }, set.AtlasFooterBackground)
		assert.are.same({ fg = "#1c1e26", bg = "#eef1f8", bold = true, default = true }, set.AtlasFooterActive)
		assert.are.same({ bg = "#40a02b", fg = "#ffffff", bold = true, default = true }, set.AtlasPROpenChip)
		assert.are.same({ fg = 0x1e66f5, bold = true, default = true }, set.AtlasMarkdownHeading2)
	end)

	it("builds the dynamic palette from standard highlights", function()
		highlights.setup()

		assert.are.same({ link = "Function", default = true }, set.AtlasDynColor01)
		assert.are.same({ bg = "#1e66f5", fg = "#ffffff", bold = true, default = true }, set.AtlasDynBgColor01)
	end)

	it("keeps chip names and colors stable for provider colors", function()
		highlights.setup()
		local name = highlights.chip("#40a02b")

		assert.are.equal("AtlasChip_40a02b_ffffff", name)
		assert.are.same({ bg = "#40a02b", fg = "#ffffff", bold = true, default = true }, set[name])
		assert.are.equal(name, highlights.chip(0x40a02b))
		assert.are.equal("AtlasTextMuted", highlights.chip("not-a-color"))
	end)

	it("builds label highlights from provider colors", function()
		highlights.setup()

		assert.are.equal("AtlasLabel_40a02b", highlights.label("#40a02b"))
		assert.is_not_nil(set.AtlasLabel_40a02b)
		assert.are.equal("AtlasLabel_40a02b", highlights.label(0x40a02b))
		assert.are.equal("AtlasTextMuted", highlights.label("not-a-color"))
	end)

	it("maps identifiers to a stable palette", function()
		assert.are.equal(highlights.dynamic_for("alice"), highlights.dynamic_for("alice"))
		assert.is_truthy(highlights.dynamic_for("alice"):match("^AtlasDynColor%d%d$"))
		assert.is_truthy(highlights.dynamic_for_bg("alice"):match("^AtlasDynBgColor%d%d$"))
		assert.is_nil(highlights.dynamic_for(nil))
		assert.is_nil(highlights.dynamic_for_bg(""))
	end)

	it("does not require a colorscheme", function()
		theme = {}
		assert.has_no.errors(highlights.setup)
		assert.are.same({ default = true }, set.AtlasTextMuted)
		assert.are.same({ default = true }, set.AtlasCodeBackground)
		assert.are.same({ bold = true, default = true }, set.AtlasPROpenChip)
	end)
end)
