describe("ui.navigation issue boards", function()
	local navigation, state, lines, cursor, view, marks, options, pending_select, selected
	local original_api, original_fn, original_defer
	local saved_modules
	local modules = { "atlas.ui.navigation", "atlas.ui.dashboard", "atlas.ui.state", "atlas.issues.ui.dashboard" }

	before_each(function()
		saved_modules = {}
		for _, name in ipairs(modules) do
			saved_modules[name] = package.loaded[name]
		end
		original_api, original_fn, original_defer = vim.api, vim.fn, vim.defer_fn
		cursor, view, marks, options = { 1, 0 }, { leftcol = 0 }, {}, {}
		pending_select, selected = nil, nil
		local line_map
		lines, line_map = require("atlas.issues.ui.dashboard.board").render({
			provider_id = "jira",
			statuses = {
				{ id = "todo", name = "To do" },
				{ id = "active", name = "In progress" },
				{ id = "done", name = "Done" },
			},
			issues = {
				{ key = "KAN-1", title = "Café", status_id = "todo", status = "To do" },
				{ key = "KAN-2", title = "First active", status_id = "active", status = "In progress" },
				{ key = "KAN-3", title = "Second active", status_id = "active", status = "In progress" },
			},
		})
		state = { domain = "issues", line_map = line_map }
		package.loaded["atlas.ui.state"] = state
		package.loaded["atlas.ui.dashboard"] = {
			win = function()
				return 1
			end,
			buf = function()
				return 2
			end,
			is_active = function()
				return true
			end,
		}
		package.loaded["atlas.issues.ui.dashboard"] = {
			select = function(item)
				selected = item
			end,
		}
		vim.api = vim.tbl_extend("force", original_api, {
			nvim_win_get_cursor = function()
				return cursor
			end,
			nvim_win_set_cursor = function(_, value)
				cursor = value
			end,
			nvim_buf_line_count = function()
				return #lines
			end,
			nvim_win_get_width = function()
				return 60
			end,
			nvim_win_call = function(_, callback)
				callback()
			end,
			nvim_buf_clear_namespace = function()
				marks = {}
			end,
			nvim_buf_set_extmark = function(_, _, row, col, opts)
				marks[#marks + 1] = { row = row, col = col, opts = opts }
			end,
			nvim_set_option_value = function(name, value)
				options[name] = value
			end,
		})
		vim.fn = vim.tbl_extend("force", original_fn, {
			winsaveview = function()
				return vim.deepcopy(view)
			end,
			winrestview = function(value)
				view = value
			end,
		})
		vim.defer_fn = function(callback)
			pending_select = callback
			return { stop = function() end, close = function() end }
		end
		package.loaded["atlas.ui.navigation"] = nil
		navigation = require("atlas.ui.navigation")
	end)

	after_each(function()
		vim.api, vim.fn, vim.defer_fn = original_api, original_fn, original_defer
		for _, name in ipairs(modules) do
			package.loaded[name] = saved_modules[name]
		end
	end)

	it("uses byte offsets for selection and display columns for horizontal scrolling", function()
		navigation.focus_first_item()
		assert.equals("KAN-1", navigation.current_item().key)
		navigation.move_column(1)
		local item = navigation.current_item()
		assert.equals("KAN-2", item.key)
		assert.is_true(item.start_col > item.virt_col)
		assert.same({ 2, item.start_col }, cursor)
		assert.equals(item.virt_col + item.width - 60, view.leftcol)
		assert.is_false(options.cursorline)
		assert.equals(item.start_col, marks[1].col)
		assert.equals(item.end_col, marks[1].opts.end_col)
		pending_select()
		assert.equals("KAN-2", selected.key)
	end)

	it("keeps vertical and first/last navigation inside the selected column", function()
		navigation.focus_first_item()
		navigation.move_column(1)
		navigation.move_cursor("down")
		assert.equals("KAN-3", navigation.current_item().key)
		navigation.focus_first_item()
		assert.equals("KAN-2", navigation.current_item().key)
		navigation.focus_last_item()
		assert.equals("KAN-3", navigation.current_item().key)
		navigation.move_cursor("up")
		assert.equals("KAN-2", navigation.current_item().key)
		navigation.move_column(-1)
		navigation.move_cursor("down")
		assert.equals("KAN-1", navigation.current_item().key)
	end)

	it("allows crossing empty columns without selecting a different issue", function()
		navigation.focus_first_item()
		navigation.move_column(2)
		assert.equals("issue_column", navigation.current_item().kind)
		assert.equals(3, navigation.current_item().column)
		assert.same({}, marks)
		navigation.move_cursor("down")
		assert.equals(2, cursor[1])
		navigation.move_column(-1)
		assert.equals("KAN-2", navigation.current_item().key)
	end)

	it("finds an issue by key across columns after a refresh", function()
		assert.is_true(navigation.focus_item(function(item)
			return item.key == "KAN-3"
		end))
		assert.equals("KAN-3", navigation.current_item().key)
		assert.same({ 3, state.line_map[3].cells[2].start_col }, cursor)
	end)

	it("restores row selection when returning to a plain list", function()
		navigation.focus_first_item()
		state.line_map = { [1] = { kind = "bookmark", name = "Saved search" }, [3] = { kind = "issue", key = "KAN-4" } }
		navigation.focus_first_item()
		assert.equals("bookmark", navigation.current_item().kind)
		assert.is_true(options.cursorline)
		assert.same({}, marks)
		navigation.move_cursor("down")
		assert.equals("KAN-4", navigation.current_item().key)
	end)
end)
