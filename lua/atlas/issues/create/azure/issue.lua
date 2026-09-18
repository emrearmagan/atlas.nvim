local M = {}

local form = require("atlas.ui.popups.form")
local icons = require("atlas.ui.shared.icons")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local picker = require("atlas.ui.picker")
local requests = require("atlas.core.requests")

---@param item_types table[]
---@return table|nil
local function default_type(item_types)
	for _, item_type in ipairs(item_types) do
		if item_type.name:lower() == "task" then
			return item_type
		end
	end
	return item_types[1]
end

---@param project string
---@param item_types table[]
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@param opts { issue?: AzureIssue, description?: string, description_format?: string }|nil
function M.open(project, item_types, on_done, opts)
	opts = opts or {}
	local issue = opts.issue
	local initial_title = issue and issue.title or ""
	local initial_body = opts.description or ""
	local initial_type = issue and issue.type or default_type(item_types)
	local initial_type_name = initial_type and initial_type.name
	require("atlas.issues.ui.highlights").setup()
	local state = {
		layout = {},
		content_width = 80,
		is_submitting = false,
		item_type = initial_type,
		requests = requests.new(),
	}
	local function meta_rows()
		local name = state.item_type and state.item_type.name or "None"
		local icon, hl = icons.issues_type(name)
		return { { "Project:", project, "Type:", { text = icon .. " " .. name, hl = hl } } }
	end
	local function change_type()
		picker.select({
			title = "Work item type",
			items = item_types,
			format_item = function(item_type)
				local icon, hl = icons.issues_type(item_type.name)
				return icon .. " " .. item_type.name, hl
			end,
			on_select = function(item_type)
				if item_type then
					state.item_type = item_type
					form.render_meta(state, meta_rows())
				end
			end,
		})
	end
	local function close(cancelled)
		state.requests.cancel()
		form.close(state.layout)
		if cancelled then
			on_done(nil, nil)
		end
	end
	form.open(state, {
		title_label = "Title",
		body_label = "Description",
		initial_title = initial_title,
		initial_body = initial_body,
		meta = meta_rows,
		keymaps = {
			{ key = "gt", buffers = { "editor" }, action = change_type, desc = "work item type" },
		},
		close = function()
			if
				form.get_title(state.layout) == initial_title
				and form.get_body(state.layout) == initial_body
				and (state.item_type and state.item_type.name) == initial_type_name
			then
				close(true)
				return
			end
			local prompt = issue and "Discard changes? [y/N]: " or "Discard work item? [y/N]: "
			vim.ui.input({ prompt = prompt }, function(input)
				if vim.trim(input or ""):lower() == "y" then
					close(true)
				end
			end)
		end,
		submit = function()
			if state.is_submitting then
				return
			end
			local title = vim.trim(form.get_title(state.layout))
			if title == "" then
				form.notify("warn", "Title is required")
				return
			end
			if not state.item_type then
				form.notify("warn", "Work item type is required")
				return
			end
			state.is_submitting = true
			form.notify("loading", issue and "Updating work item..." or "Creating work item...")
			local fields = { ["System.Title"] = title }
			local description = form.get_body(state.layout)
			if not issue or description ~= initial_body then
				fields["System.Description"] = description
			end
			if issue and state.item_type.name ~= initial_type_name then
				fields["System.WorkItemType"] = state.item_type.name
			end
			state.requests.run(function(done)
				if issue then
					return issues_api.update(issue, fields, function(ok, err)
						done(ok and issue or nil, err)
					end, { format = opts.description_format })
				end
				return issues_api.create(project, state.item_type.name, fields, done)
			end, function(saved_issue, err)
				state.is_submitting = false
				if err then
					form.notify("error", err)
					return
				end
				close(false)
				on_done(saved_issue, nil)
			end)
		end,
	})
end

return M
