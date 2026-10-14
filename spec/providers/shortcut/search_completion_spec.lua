describe("Shortcut search completion", function()
	local module_name = "atlas.providers.shortcut.completion.search"
	local prompt_name = "atlas.ui.prompt"
	local original_module, original_prompt
	local prompt_options

	before_each(function()
		original_module = package.loaded[module_name]
		original_prompt = package.loaded[prompt_name]
		package.loaded[module_name] = nil
		package.loaded[prompt_name] = {
			open = function(opts)
				prompt_options = opts
			end,
		}
		require(module_name).edit("", function() end)
	end)

	after_each(function()
		package.loaded[module_name] = original_module
		package.loaded[prompt_name] = original_prompt
	end)

	local function complete(query, suffix)
		local cmdline = "AtlasShortcutSearch " .. query
		return prompt_options.complete("", cmdline .. (suffix or ""), #cmdline)
	end

	it("completes native operators and values in the current clause", function()
		assert.same({ "owner:" }, complete('type:bug label:"needs review" ow'))
		assert.same({ "!owner:" }, complete("!ow"))
		assert.same({ "-type:bug" }, complete("-type:b"))
	end)

	it("respects quoted values and the cursor position", function()
		assert.same({}, complete([[label:"needs \"quoted ow]]))
		assert.same({ "owner:" }, complete("type:bug ow", "ner:alice !is:done"))
		assert.same({}, complete('label:"needs ow', '" owner:alice'))
	end)

	it("leaves unknown operators and workspace values alone", function()
		assert.same({}, complete("owner:ali"))
		assert.same({}, complete("custom:va"))
	end)
end)
