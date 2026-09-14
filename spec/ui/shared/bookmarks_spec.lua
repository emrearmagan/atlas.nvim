local config = require("atlas.config")
local bookmarks = require("atlas.ui.shared.bookmarks")

describe("shared bookmarks", function()
	local original_domain_options

	before_each(function()
		original_domain_options = config.domain_options
	end)

	after_each(function()
		config.domain_options = original_domain_options
	end)

	it("renders Starred before string and full-view bookmarks", function()
		local extra_params = { sort = "recentupdate" }
		---@diagnostic disable-next-line: duplicate-set-field
		config.domain_options = function(provider, domain)
			assert.equal("gitea", provider)
			assert.equal("pulls", domain)
			return {
				bookmarks = {
					items = {
						["Simple search"] = "is:merged author:@me",
						["Full view"] = {
							layout = "plain",
							repo = "owner/repository",
							search = "authentication",
							extra_params = extra_params,
						},
					},
				},
			}
		end

		local state = bookmarks.new("gitea", "pulls")
		local base_view = { name = "Pull Requests" }
		---@diagnostic disable-next-line: missing-fields
		local saved_items = { { ref = "gitea:pulls/owner/repository#1" } }
		local views = bookmarks.views({ base_view }, state, saved_items)
		assert.is_true(views[1] == base_view)
		assert.is_true(views[2] == state.tab)

		local lines, spans, line_map = {}, {}, {}
		bookmarks.render(lines, spans, line_map, 120, state, saved_items)

		assert.is_truthy(lines[1]:find("Bookmarks", 1, true))
		assert.equal("starred", line_map[2].kind)

		local full = line_map[3]
		assert.equal("bookmark", full.kind)
		assert.equal("Full view", full.view.name)
		assert.equal("plain", full.view.layout)
		assert.equal("owner/repository", full.view.repo)
		assert.equal("authentication", full.view.search)
		assert.is_true(full.view.extra_params == extra_params)

		local simple = line_map[4]
		assert.equal("bookmark", simple.kind)
		assert.equal("Simple search", simple.view.name)
		assert.equal("compact", simple.view.layout)
		assert.equal("is:merged author:@me", simple.view.search)
	end)
end)
