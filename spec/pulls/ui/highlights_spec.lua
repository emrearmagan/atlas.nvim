local highlights = require("atlas.pulls.ui.highlights")

describe("pulls.ui.highlights", function()
	before_each(function()
		vim.api.__reset_highlights()
	end)

	it("defines its groups when nothing has set them yet", function()
		highlights.setup()

		assert.are.same({ fg = "#86efac", default = true }, vim.api.nvim_get_hl(0, { name = "AtlasPROpen" }))
	end)

	it("does not clobber a group a colorscheme already defined", function()
		vim.api.nvim_set_hl(0, "AtlasPROpen", { fg = "#00ff00" })

		highlights.setup()

		assert.are.same({ fg = "#00ff00" }, vim.api.nvim_get_hl(0, { name = "AtlasPROpen" }))
	end)

	it("keeps a colorscheme override across repeated setup() calls", function()
		vim.api.nvim_set_hl(0, "AtlasPRMerged", { fg = "#654321" })

		highlights.setup()
		highlights.setup()

		assert.are.same({ fg = "#654321" }, vim.api.nvim_get_hl(0, { name = "AtlasPRMerged" }))
	end)

	it("also sets up the shared groups it depends on", function()
		highlights.setup()

		assert.is_not_nil(vim.api.nvim_get_hl(0, { name = "AtlasGitHubTheme" }).bg)
	end)
end)
