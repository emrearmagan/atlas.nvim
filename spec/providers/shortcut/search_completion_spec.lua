describe("Shortcut search completion", function()
	local module_name = "atlas.providers.shortcut.completion.search"
	local prompt_name = "atlas.commands.search.prompt"
	local original_module, original_prompt
	local prompt_options, submitted

	before_each(function()
		original_module = package.loaded[module_name]
		original_prompt = package.loaded[prompt_name]
		package.loaded[module_name] = nil
		package.loaded[prompt_name] = {
			open = function(opts)
				prompt_options = opts
			end,
		}
		submitted = {}
		require(module_name).edit("!is:done ", function(query)
			table.insert(submitted, query)
		end)
	end)

	after_each(function()
		package.loaded[module_name] = original_module
		package.loaded[prompt_name] = original_prompt
	end)

	local function complete(query, suffix)
		local cmdline = "AtlasShortcutSearch " .. query
		return prompt_options.complete("", cmdline .. (suffix or ""), #cmdline)
	end

	it("opens the shared prompt with the current query", function()
		assert.equal("AtlasShortcutSearch", prompt_options.name)
		assert.equal("!is:done ", prompt_options.default)
	end)

	it("completes an operator prefix", function()
		assert.same({ "owner:" }, complete("ow"))
		assert.same({ "owner:" }, complete("OW"))
	end)

	it("completes the last clause without changing earlier clauses", function()
		assert.same({ "owner:" }, complete('type:bug label:"needs review" ow'))
		assert.same({ "type:bug" }, complete("owner:alice type:b"))
	end)

	it("offers operators after a complete clause", function()
		local result = table.concat(complete("type:bug "), " ")
		assert.is_true(result:find("owner:", 1, true) ~= nil)
		assert.is_true(result:find("label:", 1, true) ~= nil)
	end)

	it("preserves exclusions when completing operators and values", function()
		assert.same({ "!owner:" }, complete("!ow"))
		assert.same({ "-owner:" }, complete("-ow"))
		assert.same({ "!is:done" }, complete("!is:d"))
		assert.same({ "-type:bug" }, complete("-type:b"))
	end)

	it("offers static values for native operators", function()
		assert.same({ "type:bug", "type:chore", "type:feature" }, complete("type:"))
		assert.same({ "has:owner" }, complete("has:ow"))
		assert.same({ "due:today", "due:tomorrow" }, complete("due:to"))
		assert.same({ "created:today" }, complete("created:to"))
	end)

	it("does not offer operators or values inside quoted text", function()
		assert.same({}, complete('label:"needs ow'))
		assert.same({}, complete('"ow'))
		assert.same({}, complete('type:"b'))
		assert.same({}, complete('label:"needs ow"'))
	end)

	it("keeps escaped quotes within the quoted value", function()
		assert.same({}, complete([[label:"needs \"quoted ow]]))
		assert.same({ "owner:" }, complete([[label:"needs \"quoted\" review" ow]]))
	end)

	it("only considers text before the cursor", function()
		assert.same({ "owner:" }, complete("type:bug ow", "ner:alice !is:done"))
		assert.same({}, complete('label:"needs ow', '" owner:alice'))
	end)

	it("leaves unknown operators and workspace values alone", function()
		assert.same({}, complete("owner:ali"))
		assert.same({}, complete("state:rev"))
		assert.same({}, complete("custom:va"))
		assert.same({}, complete("unknown"))
	end)

	it("passes the submitted native query through after trimming its edges", function()
		local query = 'owner:alice  label:"needs review" !is:done custom:value'
		prompt_options.on_submit("  " .. query .. "  ")
		assert.same({ query }, submitted)
	end)

	it("ignores empty submissions", function()
		prompt_options.on_submit("")
		prompt_options.on_submit("   ")
		prompt_options.on_submit(nil)
		assert.same({}, submitted)
	end)
end)
