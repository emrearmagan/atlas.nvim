local api = require("atlas.issues.providers.shortcut.api")
local bookmarks = require("atlas.ui.shared.bookmarks")
local config = require("atlas.config")
local providers = require("atlas.providers")

describe("Shortcut config", function()
	local original_options
	local original_search

	before_each(function()
		original_options = config.options
		original_search = api.stories.search
		config.options = {
			providers = { shortcut = { token = "shortcut-test-token" } },
			issues = { shortcut = {} },
		}
	end)

	after_each(function()
		config.options = original_options
		rawset(api.stories, "search", original_search)
	end)

	it("uses the resolved view search unchanged", function()
		local expression = 'owner:"Jane Doe" !is:done !is:archived'
		config.options.issues.shortcut.views = {
			{ name = "Mine", layout = "plain", search = expression },
		}
		local provider = assert(providers.load("shortcut", "issues"))
		---@cast provider IssuesProvider
		local view = provider.views()[1]
		local received

		rawset(api.stories, "search", function(query, opts, on_done)
			received = { query = query, opts = opts, on_done = on_done }
		end)

		local opts = { pagelen = 25 }
		local on_done = function() end
		provider.capabilities.core.fetch_issues(view, opts, on_done)

		assert.are.equal(expression, provider.resolve_search(view))
		assert.same({ query = expression, opts = opts, on_done = on_done }, received)
	end)

	it("accepts string and full-view bookmarks", function()
		config.options.issues.shortcut.bookmarks = {
			items = {
				Simple = "type:bug !is:done",
				Full = { layout = "plain", search = 'label:"needs review" !is:done' },
			},
		}
		local provider = assert(providers.load("shortcut", "issues"))
		local state = bookmarks.new("shortcut", "issues")
		local line_map = {}
		bookmarks.render({}, {}, line_map, 200, state, {})

		local views = {}
		for _, node in pairs(line_map) do
			views[node.view.name] = node.view
		end

		assert.same({ name = "Simple", layout = "compact", search = "type:bug !is:done" }, views.Simple)
		assert.same({ name = "Full", layout = "plain", search = 'label:"needs review" !is:done' }, views.Full)
		assert.are.equal("type:bug !is:done", provider.resolve_search(views.Simple))
		assert.are.equal('label:"needs review" !is:done', provider.resolve_search(views.Full))
	end)
end)
