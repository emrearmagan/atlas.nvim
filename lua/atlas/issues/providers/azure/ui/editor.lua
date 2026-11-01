local M = {}

local form = require("atlas.ui.form")
local icons = require("atlas.ui.shared.icons")
local issues = require("atlas.issues.providers.azure.api.issues")
local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local requests = require("atlas.core.requests")
local users = require("atlas.providers.azure.users")

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
---@param issue AzureIssue|nil
---@param details AzureIssueDetails|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return AtlasForm
local function open_editor(project, item_types, issue, details, on_done)
	local initial_title = details and details.title or (issue and issue.title or "")
	local initial_body = details and details.description or ""
	local item_type = issue and issue.type or default_type(item_types)
	local initial_type_name = item_type and item_type.name
	local assignee = details and details.assignees[1]
	local initial_assignee = assignee and assignee.username
	local tags = table.concat(
		vim.tbl_map(function(label)
			return label.name
		end, details and details.labels or {}),
		"; "
	)
	local initial_tags = tags
	local loading_members = false
	local submitting = false

	local function is_modified(editor)
		local content = form.get_content(editor)
		return content.title ~= initial_title
			or content.body ~= initial_body
			or (item_type and item_type.name) ~= initial_type_name
			or (assignee and assignee.username) ~= initial_assignee
			or tags ~= initial_tags
	end

	return form.open({
		header = issue and "Edit work item #" .. issue.key or "Create work item",
		initial_title = initial_title,
		initial_body = initial_body,
		completion = {
			context = { provider = "azure", project = project, issue = issue and { key = issue.key } },
		},
		is_modified = is_modified,
		meta = function()
			local name = item_type and item_type.name or "None"
			local icon, hl = icons.get("issue")
			return {
				{
					{ key = "Project:", value = project },
					{ key = "Type:", value = icon .. " " .. name, hl = hl },
				},
				{
					{
						key = "Assignee:",
						value = icons.get("user") .. " " .. (assignee and assignee.name or "Unassigned"),
						hl = assignee and "Normal" or "AtlasTextMuted",
						loading = loading_members,
					},
					{
						key = "Tags:",
						value = tags ~= "" and tags or "None",
						hl = tags ~= "" and "Normal" or "AtlasTextMuted",
					},
				},
			}
		end,
		keymaps = {
			{
				key = keymaps.resolve("editor.issue_type"),
				desc = "work item type",
				action = function(editor)
					if submitting then
						return
					end
					picker.select({
						title = "Work item type",
						items = item_types,
						format_item = function(value)
							local icon, hl = icons.get("issue")
							return icon .. " " .. value.name, hl
						end,
						on_select = function(value)
							if value and not editor.closed and not submitting then
								item_type = value
								form.render_meta(editor)
							end
						end,
					})
				end,
			},
			{
				key = keymaps.resolve("editor.assignees"),
				desc = "assignee",
				action = function(editor)
					if submitting or loading_members then
						return
					end
					loading_members = true
					editor.statusline:notify("loading", "Loading members...")
					form.render_meta(editor)

					users.fetch_project_members(project, function(members, err)
						loading_members = false
						if editor.closed or submitting then
							return
						end
						form.render_meta(editor)
						if err then
							editor.statusline:notify("error", err)
							return
						end
						editor.statusline:clear_notice()

						local items = { { name = "Unassigned", username = "" } }
						local seen = {}
						for _, member in ipairs(members or {}) do
							local user = users.to_user(member)
							if user and user.username and not seen[user.username] then
								seen[user.username] = true
								table.insert(items, user)
							end
						end

						picker.select({
							title = "Assignee",
							items = items,
							format_item = function(user)
								if user.username == "" then
									return user.name
								end
								return string.format("%s %s (%s)", icons.get("user"), user.name, user.username)
							end,
							on_select = function(user)
								if user and not editor.closed and not submitting then
									assignee = user.username ~= "" and user or nil
									form.render_meta(editor)
								end
							end,
						})
					end)
				end,
			},
			{
				key = keymaps.resolve("editor.labels"),
				desc = "tags",
				action = function(editor)
					if submitting then
						return
					end
					vim.ui.input({ prompt = "Tags (separated by ;): ", default = tags }, function(input)
						if input and not editor.closed and not submitting then
							tags = vim.trim(input)
							form.render_meta(editor)
						end
					end)
				end,
			},
		},
		close = function(editor)
			if submitting then
				return
			elseif not is_modified(editor) then
				form.close(editor)
				return
			end
			vim.ui.input({ prompt = "Discard work item changes? [y/N]: " }, function(input)
				if not submitting and vim.trim(input or ""):lower() == "y" then
					form.close(editor)
				end
			end)
		end,
		on_closed = function()
			if not submitting then
				on_done(nil, nil)
			end
		end,
		submit = function(editor)
			if submitting then
				return
			end
			local content = form.get_content(editor)
			local title = vim.trim(content.title)
			if title == "" then
				editor.statusline:notify("warn", "Title is required")
				return
			end
			if not item_type then
				editor.statusline:notify("warn", "Work item type is required")
				return
			end
			if issue and not is_modified(editor) then
				form.close(editor)
				return
			end
			submitting = true
			vim.bo[editor.editor_buf].modifiable = false
			editor.statusline:notify("loading", issue and "Updating work item..." or "Creating work item...")
			local fields = { ["System.Title"] = title }
			if not issue or content.body ~= initial_body then
				fields["System.Description"] = content.body
			end
			if issue and item_type.name ~= initial_type_name then
				fields["System.WorkItemType"] = item_type.name
			end
			if (assignee and assignee.username) ~= initial_assignee then
				fields["System.AssignedTo"] = assignee and assignee.username or ""
			end
			if tags ~= initial_tags then
				fields["System.Tags"] = tags
			end
			local function done(saved_issue, err)
				if not saved_issue then
					submitting = false
					err = err or "Unable to save work item"
					if not editor.closed then
						vim.bo[editor.editor_buf].modifiable = true
						editor.statusline:notify("error", err)
					else
						notify.error(err)
						on_done(nil, err)
					end
					return
				end
				form.close(editor)
				submitting = false
				on_done(saved_issue, nil)
			end
			if issue then
				issues.update(issue, fields, function(ok, err)
					done(ok and issue or nil, err)
				end, { format = details and details.description_format })
			else
				issues.create(project, item_type.name, fields, done)
			end
		end,
	})
end

---@param project string
---@param issue AzureIssue|nil
---@param details AzureIssueDetails|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function load_types(project, issue, details, on_done)
	notify.loading("Loading work item types...")
	return issues.list_types(project, function(item_types, err)
		if not item_types then
			err = err or "Unable to load work item types"
			notify.error(err)
			on_done(nil, err)
			return
		end
		notify.clear()
		open_editor(project, item_types, issue, details, on_done)
	end)
end

---@param project string
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.open(project, on_done)
	return load_types(project, nil, nil, on_done)
end

---@param issue AzureIssue
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return AtlasRequestScope
function M.edit(issue, on_done)
	notify.loading("Loading work item...")
	local scope = requests.new()
	scope.run(function(done)
		return issues.fetch_issue(issue, { force_refresh = true }, done)
	end, function(details, err)
		if not details then
			err = err or "Unable to load work item"
			notify.error(err)
			on_done(nil, err)
			return
		end
		---@cast details AzureIssueDetails
		scope.run(function(done)
			return load_types(issue.project, issue, details, done)
		end, on_done)
	end)
	return scope
end

return M
