local emojis = require("atlas.ui.shared.emojis")

describe("ui.shared.reactions", function()
	local modules = { "atlas.ui.picker", "atlas.core.notify", "atlas.ui.shared.reactions" }
	local original_loaded, reactions, select, notified

	before_each(function()
		original_loaded = {}
		for _, name in ipairs(modules) do
			original_loaded[name] = package.loaded[name]
		end
		notified = {}
		package.loaded["atlas.ui.picker"] = {
			select = function(opts)
				select = opts
			end,
		}
		package.loaded["atlas.core.notify"] = setmetatable({}, {
			__index = function(_, level)
				return function(message)
					notified[#notified + 1] = level .. ": " .. message
				end
			end,
		})
		package.loaded["atlas.ui.shared.reactions"] = nil
		reactions = require("atlas.ui.shared.reactions")
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = original_loaded[name]
		end
	end)

	it("formats reactions with glyph and count spans", function()
		local thumbsup, fire = emojis.get("thumbsup"), emojis.get("fire")
		local text, spans = reactions.format({ { name = "thumbsup", count = 2 }, { name = "fire", count = 1 } })
		local second = #thumbsup + 4
		assert.equal(thumbsup .. " 2  " .. fire .. " 1", text)
		assert.same({
			{ line = 0, start_col = 0, end_col = #thumbsup, hl_group = "AtlasLogInfo" },
			{ line = 0, start_col = #thumbsup, end_col = #thumbsup + 2, hl_group = "AtlasTextMuted" },
			{ line = 0, start_col = second, end_col = second + #fire, hl_group = "AtlasLogInfo" },
			{ line = 0, start_col = second + #fire, end_col = second + #fire + 2, hl_group = "AtlasTextMuted" },
		}, spans)
		assert.equal("", reactions.format(nil))
	end)

	it("adds the API key and updates the comment's counts", function()
		local added, done = {}, 0
		local capability = {
			options = { { name = "thumbsup", key = "+1" }, { name = "tada", key = "hooray" } },
			add = function(_, _, key, on_done)
				added[#added + 1] = key
				on_done(true, nil)
			end,
		}
		local comment = { reactions = { { name = "thumbsup", count = 1 } } }
		local function pick(index)
			reactions.pick(capability, {}, comment, function()
				return true
			end, function()
				done = done + 1
			end)
			select.on_select(capability.options[index])
		end

		pick(1)
		pick(2)

		assert.same({ "+1", "hooray" }, added)
		assert.same(
			{ { name = "thumbsup", count = 2, reacted = true }, { name = "tada", count = 1, reacted = true } },
			comment.reactions
		)
		assert.equal(2, done)
	end)

	it("removes your own reaction when you pick it again", function()
		local removed, added = {}, {}
		local capability = {
			options = { { name = "thumbsup", key = "THUMBS_UP" }, { name = "heart", key = "HEART" } },
			add = function(_, _, key, on_done)
				added[#added + 1] = key
				on_done(true, nil)
			end,
			remove = function(_, _, key, on_done)
				removed[#removed + 1] = key
				on_done(true, nil)
			end,
		}
		local comment = {
			reactions = {
				{ name = "thumbsup", count = 2, users = { { username = "alice" } }, reacted = true },
				{ name = "heart", count = 1, reacted = true },
			},
		}
		reactions.pick(capability, {}, comment, function()
			return true
		end, function() end)

		assert.equal("React", select.title)
		assert.equal(emojis.get("thumbsup") .. " thumbsup by alice +1 (you)", (select.format_item(select.items[1])))
		select.on_select(select.items[1])
		select.on_select(select.items[2])

		assert.same({ "THUMBS_UP", "HEART" }, removed)
		assert.same({}, added)
		assert.same(
			{ { name = "thumbsup", count = 1, users = { { username = "alice" } }, reacted = false } },
			comment.reactions
		)
		assert.same("success: Reaction removed", notified[#notified])
	end)

	it("lists existing reactions first with who reacted, then the other options", function()
		local capability = { options = { { name = "thumbsup", key = "+1" }, { name = "heart" }, { name = "eyes" } } }
		local users = { { username = "alice" }, { name = "Bob" }, { username = "carol" }, { username = "dave" } }
		local comment = {
			reactions = {
				{ name = "heart", count = 2 },
				{ name = "fire", count = 1, users = { { username = "erin" } } },
				{ name = "thumbsup", count = 5, users = users },
			},
		}
		reactions.pick(capability, {}, comment, function()
			return true
		end, function() end)

		local names = {}
		for _, item in ipairs(select.items) do
			names[#names + 1] = item.name
		end
		assert.same({ "heart", "fire", "thumbsup", "eyes" }, names)
		assert.equal("+1", select.items[3].key)

		local icon = emojis.get("thumbsup")
		local text, chunks = select.format_item(select.items[3])
		assert.equal(icon .. " thumbsup by alice, Bob, carol +2", text)
		assert.same({
			{ icon, "AtlasLogInfo" },
			{ " thumbsup", "Normal" },
			{ " by alice, Bob, carol +2", "AtlasTextMuted" },
		}, chunks)
		assert.equal(emojis.get("heart") .. " heart    by 2 users", (select.format_item(select.items[1])))
		assert.equal(emojis.get("eyes") .. " eyes", (select.format_item(select.items[4])))
	end)

	it("leaves counts alone when adding fails or the view moved on", function()
		local comment, done = {}, 0
		local current = true
		local capability = {
			options = { { name = "heart" } },
			add = function(_, _, _, on_done)
				on_done(false, "boom")
			end,
		}
		for _, is_current in ipairs({ true, false }) do
			current = is_current
			reactions.pick(capability, {}, comment, function()
				return current
			end, function()
				done = done + 1
			end)
			select.on_select(capability.options[1])
		end

		assert.is_nil(comment.reactions)
		assert.equal(0, done)
		assert.same(
			{ "loading: Adding reaction...", "error: Reaction failed: boom", "loading: Adding reaction..." },
			notified
		)
	end)
end)
