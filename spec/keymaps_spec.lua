local config = require("atlas.config")
local keymaps = require("atlas.core.keymaps")

local function deep_copy(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for k, v in pairs(value) do
		copy[k] = deep_copy(v)
	end
	return copy
end

local default_keymaps = {
	ui = {
		toggle_panel = "p",
		next_panel_tab = { "]", "<Tab>" },
	},
}

local shipped_keymaps = deep_copy(config.options.keymaps)

describe("atlas keymaps resolver", function()
	before_each(function()
		config.options.keymaps = deep_copy(default_keymaps)
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

describe("atlas keymap conflicts", function()
	before_each(function()
		config.options.keymaps = deep_copy(shipped_keymaps)
	end)

	it("reports no conflicts for the shipped defaults", function()
		for section, conflicts in pairs(keymaps.validate()) do
			assert.are.same({}, conflicts, string.format("unexpected conflicts in %s", section))
		end
	end)

	it("includes navigation keys in domain conflicts", function()
		config.options.keymaps.ui.next_item = "gd"

		local pulls_conflicts = keymaps.validate().pulls
		assert.are.same({ "pulls.open_diff", "ui.next_item" }, pulls_conflicts["gd"])
	end)
end)
