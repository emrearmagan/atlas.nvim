local config = require("atlas.config")
local keymaps = require("atlas.core.keymaps")

local default_keymaps = {
	ui = {
		toggle_panel = "p",
		next_panel_tab = { "]", "<Tab>" },
	},
}

local shipped_keymaps = vim.deepcopy(config.options.keymaps)

describe("core.keymaps", function()
	after_each(function()
		config.options.keymaps = vim.deepcopy(shipped_keymaps)
	end)

	describe("resolver", function()
		before_each(function()
			config.options.keymaps = vim.deepcopy(default_keymaps)
		end)

		it("normalizes string and list mappings", function()
			assert.are.same({ "p" }, keymaps.resolve("ui.toggle_panel"))
			assert.are.same({ "]", "<Tab>" }, keymaps.resolve("ui.next_panel_tab"))
		end)

		it("returns nil for disabled and missing mappings", function()
			config.options.keymaps.ui.toggle_panel = false
			assert.is_nil(keymaps.resolve("ui.toggle_panel"))
			assert.is_nil(keymaps.resolve("ui.does_not_exist"))
		end)
	end)

	describe("conflicts", function()
		before_each(function()
			config.options.keymaps = vim.deepcopy(shipped_keymaps)
		end)

		it("reports no conflicts for the shipped defaults", function()
			for section, conflicts in pairs(keymaps.validate()) do
				assert.are.same({}, conflicts, string.format("unexpected conflicts in %s", section))
			end
		end)

		it("reports unexpected conflicts inside nested groups", function()
			config.options.keymaps.pulls.review.request_changes = "<leader>gr"
			local key = config.options.keymaps.pulls.review.request_changes
			config.options.keymaps.pulls.checkout = key

			local pulls_conflicts = keymaps.validate().pulls
			assert.are.same({
				"pulls.checkout",
				"pulls.review.request_changes",
			}, pulls_conflicts[key])
		end)
	end)
end)
