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
		toggle_fold = "za",
		toggle_all_folds = "zA",
		next_panel_tab = { "]", "<Tab>" },
		refresh = "r",
	},
	jira = {
		open_actions = "A",
		search = "/",
		manage_templates = "gT",
		refresh_tab = "r",
	},
	bitbucket = {
		checkout_pr = "gc",
		open_diffview = "gd",
		refresh_tab = "r",
		pr_files_next_hunk = "]h",
		pr_files_previous_hunk = "[h",
	},
}

local shipped_keymaps = deep_copy(config.options.keymaps)

describe("atlas keymaps resolver", function()
	before_each(function()
		config.options.keymaps = deep_copy(default_keymaps)
	end)

	it("resolves single-key mapping", function()
		assert.are.same({ "p" }, keymaps.resolve("ui.toggle_panel"))
		assert.are.same({ "za" }, keymaps.resolve("ui.toggle_fold"))
		assert.are.same({ "zA" }, keymaps.resolve("ui.toggle_all_folds"))
	end)

	it("resolves aliases for list mapping", function()
		assert.are.same({ "]", "<Tab>" }, keymaps.resolve("ui.next_panel_tab"))
	end)

	it("returns nil when keymap is disabled", function()
		config.options.keymaps.ui.toggle_panel = false
		assert.is_nil(keymaps.resolve("ui.toggle_panel"))
	end)

	it("supports alias and disable patterns used by ui modules", function()
		config.options.keymaps.ui.next_panel_tab = { "]", "<Tab>", "gn" }
		config.options.keymaps.ui.refresh = false

		local aliases = keymaps.resolve("ui.next_panel_tab")
		local disabled = keymaps.resolve("ui.refresh")

		assert.are.same({ "]", "<Tab>", "gn" }, aliases)
		assert.is_nil(disabled)
	end)

	it("resolves jira and bitbucket picker action IDs", function()
		assert.are.same({ "A" }, keymaps.resolve("jira.open_actions"))
		assert.are.same({ "/" }, keymaps.resolve("jira.search"))
		assert.are.same({ "gT" }, keymaps.resolve("jira.manage_templates"))
		assert.are.same({ "gc" }, keymaps.resolve("bitbucket.checkout_pr"))
		assert.are.same({ "gd" }, keymaps.resolve("bitbucket.open_diffview"))
	end)

	it("resolves panel action IDs", function()
		assert.are.same({ "r" }, keymaps.resolve("jira.refresh_tab"))
		assert.are.same({ "r" }, keymaps.resolve("bitbucket.refresh_tab"))
		assert.are.same({ "gc" }, keymaps.resolve("bitbucket.checkout_pr"))
	end)

	it("resolves bitbucket pr-files action IDs", function()
		assert.are.same({ "]h" }, keymaps.resolve("bitbucket.pr_files_next_hunk"))
		assert.are.same({ "[h" }, keymaps.resolve("bitbucket.pr_files_previous_hunk"))
	end)

	it("returns nil for missing or disabled mappings", function()
		config.options.keymaps.ui.toggle_fold = false
		assert.is_nil(keymaps.resolve("ui.toggle_fold"))
		assert.is_nil(keymaps.resolve("jira.does_not_exist"))
	end)
end)

describe("atlas navigation keymaps", function()
	before_each(function()
		config.options.keymaps = deep_copy(shipped_keymaps)
	end)

	it("keeps the historical hardcoded defaults", function()
		assert.are.same({ "j" }, keymaps.resolve("ui.next_item"))
		assert.are.same({ "k" }, keymaps.resolve("ui.previous_item"))
		assert.are.same({ "gg" }, keymaps.resolve("ui.first_item"))
		assert.are.same({ "G" }, keymaps.resolve("ui.last_item"))
	end)

	it("supports remapping and disabling navigation keys", function()
		config.options.keymaps.ui.next_item = ";"
		config.options.keymaps.ui.previous_item = false

		assert.are.same({ ";" }, keymaps.resolve("ui.next_item"))
		assert.is_nil(keymaps.resolve("ui.previous_item"))
	end)

	it("reports no conflicts for the shipped defaults", function()
		for section, conflicts in pairs(keymaps.validate()) do
			assert.are.same({}, conflicts, string.format("unexpected conflicts in %s", section))
		end
	end)

	it("detects conflicts against remapped navigation keys", function()
		-- "r" is already taken by ui.refresh, so the validator must flag the clash
		-- rather than checking against the old hardcoded "j".
		config.options.keymaps.ui.next_item = "r"

		local ui_conflicts = keymaps.validate().ui
		assert.are.same({ "ui.next_item", "ui.refresh" }, ui_conflicts["r"])
		assert.is_nil(ui_conflicts["j"])
	end)
end)
