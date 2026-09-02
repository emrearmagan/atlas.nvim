local highlights = require("atlas.issues.ui.highlights")

describe("issues.ui.highlights", function()
	before_each(function()
		vim.api.__reset_highlights()
	end)

	it("defines its groups when nothing has set them yet", function()
		highlights.setup()

		assert.are.same(
			{ fg = "#a6e3a1", bold = true, default = true },
			vim.api.nvim_get_hl(0, { name = "AtlasIssueOpen" })
		)
	end)

	it("does not clobber a group a colorscheme already defined", function()
		vim.api.nvim_set_hl(0, "AtlasIssueOpen", { fg = "#ff00ff" })

		highlights.setup()

		assert.are.same({ fg = "#ff00ff" }, vim.api.nvim_get_hl(0, { name = "AtlasIssueOpen" }))
	end)

	it("keeps a colorscheme override across repeated setup() calls", function()
		-- Regression test: setup() re-runs on every issues view open, so a
		-- colorscheme's override must survive more than the first call.
		vim.api.nvim_set_hl(0, "AtlasJiraKey", { fg = "#111111" })

		highlights.setup()
		highlights.setup()

		assert.are.same({ fg = "#111111" }, vim.api.nvim_get_hl(0, { name = "AtlasJiraKey" }))
	end)

	it("also sets up the shared groups it depends on", function()
		highlights.setup()

		assert.is_not_nil(vim.api.nvim_get_hl(0, { name = "AtlasJiraTheme" }).bg)
	end)
end)
