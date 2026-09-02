local highlights = require("atlas.ui.shared.highlights")

describe("ui.shared.highlights", function()
	before_each(function()
		vim.api.__reset_highlights()
	end)

	it("defines its groups when nothing has set them yet", function()
		highlights.setup()

		assert.are.same({ bg = "#1f2328", fg = "#f0f6fc", bold = true, default = true }, vim.api.nvim_get_hl(0, { name = "AtlasGitHubTheme" }))
	end)

	it("does not clobber a group a colorscheme already defined", function()
		-- Simulates a colorscheme (or user config) overriding an Atlas group
		-- before Atlas's own setup() runs.
		vim.api.nvim_set_hl(0, "AtlasGitHubTheme", { fg = "#ffffff" })

		highlights.setup()

		assert.are.same({ fg = "#ffffff" }, vim.api.nvim_get_hl(0, { name = "AtlasGitHubTheme" }))
	end)

	it("keeps a colorscheme override across repeated setup() calls", function()
		-- setup() re-runs every time a pulls/issues view opens, so the
		-- override must survive more than one call, not just the first.
		vim.api.nvim_set_hl(0, "AtlasBorder", { fg = "#123456" })

		highlights.setup()
		highlights.setup()

		assert.are.same({ fg = "#123456" }, vim.api.nvim_get_hl(0, { name = "AtlasBorder" }))
	end)

	it("defines the dynamic palette groups as defaults too", function()
		vim.api.nvim_set_hl(0, "AtlasDynColor01", { fg = "#custom" })

		highlights.setup()

		assert.are.same({ fg = "#custom" }, vim.api.nvim_get_hl(0, { name = "AtlasDynColor01" }))
		-- A dynamic group nothing overrode still gets Atlas's fallback color.
		assert.is_not_nil(vim.api.nvim_get_hl(0, { name = "AtlasDynBgColor01" }).bg)
	end)
end)
