local function fresh_actions(editor)
	local real_editor = package.loaded["atlas.ui.popups.editor"]
	package.loaded["atlas.ui.popups.editor"] = editor
	package.loaded["atlas.pulls.actions"] = nil
	local actions = require("atlas.pulls.actions")
	package.loaded["atlas.ui.popups.editor"] = real_editor
	return actions
end

---@return table editor, table opened
local function capture_editor()
	local opened = {}
	return {
		open = function(opts)
			table.insert(opened, opts)
		end,
	}, opened
end

---@param overrides table|nil
local function context(overrides)
	local notifications = {}
	local ctx = {
		provider = {
			name = "test",
			capabilities = { core = {} },
		},
		pr = { id = 7, description = "cached body" },
		notify = function(level, message)
			table.insert(notifications, { level = level, message = message })
		end,
	}
	for key, value in pairs(overrides or {}) do
		ctx[key] = value
	end
	return ctx, notifications
end

describe("pulls edit_description action", function()
	local editor, opened, actions

	before_each(function()
		editor, opened = capture_editor()
		actions = fresh_actions(editor)
	end)

	after_each(function()
		package.loaded["atlas.pulls.actions"] = nil
	end)

	it("is unavailable without a PR or without provider support", function()
		local no_pr = context({ pr = nil })
		assert.is_false(actions.edit_description.is_available(no_pr))

		local unsupported = context()
		assert.is_false(actions.edit_description.is_available(unsupported))

		local supported = context()
		supported.provider.capabilities.core.update_description = function() end
		assert.is_true(actions.edit_description.is_available(supported))
	end)

	it("seeds the editor with the freshly fetched description", function()
		local ctx = context()
		local fetch_opts
		ctx.provider.capabilities.core.fetch_description = function(_, opts, on_done)
			fetch_opts = opts
			on_done("remote body", nil)
		end
		ctx.provider.capabilities.core.update_description = function() end

		actions.edit_description.run(ctx, function() end)

		assert.is_true(fetch_opts.force_refresh)
		assert.equal(1, #opened)
		assert.equal("remote body", opened[1].initial_text)
		assert.equal("pr-description-edit-7", opened[1].key)
	end)

	it("reports a fetch failure instead of opening the editor", function()
		local ctx, notifications = context()
		ctx.provider.capabilities.core.fetch_description = function(_, _, on_done)
			on_done(nil, "boom")
		end
		ctx.provider.capabilities.core.update_description = function() end

		local result, err
		actions.edit_description.run(ctx, function(r, e)
			result, err = r, e
		end)

		assert.equal(0, #opened)
		assert.is_nil(result)
		assert.equal("boom", err)
		assert.equal("error", notifications[#notifications].level)
	end)

	it("saves the new description and marks the PR as changed", function()
		local ctx = context()
		local saved
		ctx.provider.capabilities.core.update_description = function(_, description, on_done)
			saved = description
			on_done(true, nil)
		end

		local result
		actions.edit_description.run(ctx, function(r)
			result = r
		end)
		opened[1].on_save("new body")

		assert.equal("new body", saved)
		assert.equal("new body", ctx.pr.description)
		assert.is_true(result.changed_pr)
	end)

	it("clears the description when the editor is emptied", function()
		local ctx = context()
		local saved
		ctx.provider.capabilities.core.update_description = function(_, description, on_done)
			saved = description
			on_done(true, nil)
		end

		actions.edit_description.run(ctx, function() end)
		opened[1].on_save("")

		assert.equal("", saved)
		assert.equal("", ctx.pr.description)
	end)

	it("skips the request when the text is unchanged", function()
		local ctx = context()
		local called = false
		ctx.provider.capabilities.core.update_description = function()
			called = true
		end

		local result
		actions.edit_description.run(ctx, function(r)
			result = r
		end)
		assert.equal("cached body", opened[1].initial_text)
		opened[1].on_save("cached body")

		assert.is_false(called)
		assert.is_false(result.changed_pr)
	end)

	it("surfaces update failures", function()
		local ctx, notifications = context()
		ctx.provider.capabilities.core.update_description = function(_, _, on_done)
			on_done(false, "rejected")
		end

		local result, err
		actions.edit_description.run(ctx, function(r, e)
			result, err = r, e
		end)
		opened[1].on_save("new body")

		assert.is_nil(result)
		assert.equal("rejected", err)
		assert.equal("cached body", ctx.pr.description)
		assert.equal("error", notifications[#notifications].level)
	end)

	it("reports a cancelled edit as no change", function()
		local ctx = context()
		ctx.provider.capabilities.core.update_description = function() end

		local result
		actions.edit_description.run(ctx, function(r)
			result = r
		end)
		opened[1].on_cancel()

		assert.is_false(result.changed_pr)
	end)
end)
