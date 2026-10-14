local modules = {
	"atlas.providers.azure.client",
	"atlas.providers.azure.users",
	"atlas.providers.azure.completion",
	"atlas.issues.providers.azure.api.issues",
	"atlas.issues.providers.azure.api.comments",
	"atlas.providers.azure.completion.users",
}

describe("Azure mention completion", function()
	local saved, source, calls, cache
	local pr = { pr = { id = 7, repo_full_name = "Team Project/api" } }
	local author = { id = "author", displayName = "Avery" }
	local reviewer = { id = "reviewer", displayName = "Robin" }
	local commenter = { id = "commenter", displayName = "Chris" }

	before_each(function()
		saved, calls, cache = {}, 0, {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		package.loaded[modules[1]] = {
			url_encode = require("atlas.core.utils").url_encode,
			get_cache = function(key)
				return cache[key], cache[key] ~= nil
			end,
			set_cache = function(key, value)
				cache[key] = value
			end,
			request = function(_, endpoint, _, done)
				calls = calls + 1
				if endpoint:match("/threads$") then
					done({ value = { { comments = { { author = commenter }, { author = author } } } } })
				else
					done({ createdBy = author, reviewers = { reviewer } })
				end
			end,
		}
		source = require("atlas.providers.azure.completion").users
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("formats mentions with an identity and never falls back to an email address", function()
		assert.equal("@<author>", source.format_mention({ id = "author", username = "avery@example.com" }))
		assert.is_nil(source.format_mention({ username = "avery@example.com" }))
		assert.is_nil(source.format_mention({ id = "", username = "avery@example.com" }))
	end)

	it("deduplicates PR participants and filters cached candidates per repository", function()
		local items
		local function done(result, err)
			assert.is_nil(err)
			items = result
		end
		source.complete(pr, "", done)
		assert.same(
			{ "@<author>", "@<commenter>", "@<reviewer>" },
			vim.tbl_map(function(item)
				return item.insert_text
			end, items)
		)
		source.complete(pr, "RO", done)
		assert.equal(1, #items)
		assert.equal("@<reviewer>", items[1].insert_text)
		assert.equal(2, calls)
		source.complete({ pr = { id = 7, repo_full_name = "Team Project/other" } }, "", done)
		assert.equal(4, calls)
	end)

	it("includes work-item comment authors in filtered mention candidates", function()
		package.loaded[modules[4]] = {
			fetch_by_refs = function(_, _, done)
				done({ { key = "42", project = "Team", reporter = { id = "author", name = "Avery" } } })
			end,
		}
		package.loaded[modules[5]] = {
			fetch_conversation = function(_, _, done)
				done({ { entity = { author = { id = "commenter", name = "Chris" } } } })
			end,
		}
		local items
		source.complete({ issue = { key = "42" } }, "ch", function(result, err)
			assert.is_nil(err)
			items = result
		end)
		assert.equal(1, #items)
		assert.equal("@<commenter>", items[1].insert_text)
	end)
end)
