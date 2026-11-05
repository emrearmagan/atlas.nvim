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
			assert.are.same({ "p" }, assert(keymaps.resolve("ui.toggle_panel")).key)
			assert.are.same({ "]", "<Tab>" }, assert(keymaps.resolve("ui.next_panel_tab")).key)
		end)

		it("returns the description and label", function()
			assert.are.same(
				{ key = { "p" }, desc = "Toggle detail panel", label = "panel" },
				keymaps.resolve("ui.toggle_panel")
			)
		end)

		it("merges the keys of several ids under the first description", function()
			local keymap = assert(keymaps.resolve({ "ui.toggle_panel", "ui.next_panel_tab" }))
			assert.are.same({ "p", "]", "<Tab>" }, keymap.key)
			assert.are.equal("Toggle detail panel", keymap.desc)
		end)

		it("returns nil for disabled and missing mappings", function()
			config.options.keymaps.ui.toggle_panel = false
			assert.is_nil(keymaps.resolve("ui.toggle_panel"))
			assert.is_nil(keymaps.resolve("ui.next_item"))
		end)

		it("errors for unknown action ids", function()
			assert.has_error(function()
				---@diagnostic disable-next-line: param-type-mismatch
				keymaps.resolve("ui.does_not_exist")
			end)
		end)
	end)

	describe("conflicts", function()
		before_each(function()
			config.options.keymaps = vim.deepcopy(shipped_keymaps)
		end)

		it("reports no conflicts for the shipped defaults", function()
			assert.are.same({}, keymaps.validate())
		end)

		it("reports conflicts inside the same table", function()
			config.options.keymaps.pulls.review.approve = "<leader>gr"

			assert.are.same({
				["<leader>gr"] = { "pulls.review.approve", "pulls.review.request_changes" },
			}, keymaps.validate()["pulls.review"])
		end)

		it("does not compare keys across tables", function()
			config.options.keymaps.pulls.checkout = config.options.keymaps.ui.toggle_panel

			assert.are.same({}, keymaps.validate())
		end)
	end)
end)
