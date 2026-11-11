local editor_name = "atlas.issues.providers.azure.ui.editor"
local api_name = "atlas.issues.providers.azure.api.issues"
local form_name = "atlas.ui.form"
local notify_name = "atlas.core.notify"
local module_names = { editor_name, api_name, form_name, notify_name }

describe("Azure work item updates", function()
	local original = {}
	local original_bo

	before_each(function()
		for _, name in ipairs(module_names) do
			original[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		original_bo = vim.bo
		vim.bo = { [1] = { modifiable = true } }
	end)

	after_each(function()
		vim.bo = original_bo
		for _, name in ipairs(module_names) do
			package.loaded[name] = original[name]
		end
	end)

	it("does not overwrite an unchanged HTML description when saving a title", function()
		local content, options, saved
		local handle = { editor_buf = 1, statusline = { notify = function() end } }
		package.loaded[notify_name] = { loading = function() end, clear = function() end }
		package.loaded[form_name] = {
			open = function(opts)
				options = opts
				content = { title = opts.initial_title, body = opts.initial_body }
				return handle
			end,
			get_content = function()
				return content
			end,
			close = function() end,
		}
		package.loaded[api_name] = {
			list_types = function(_, done)
				done({ { name = "Task" } })
			end,
			fetch_issue = function(_, _, done)
				done({
					title = "Title",
					description = "<p>Existing body</p>",
					description_format = "html",
					assignees = {},
					labels = {},
				})
			end,
			update = function(_, fields, done, opts)
				saved = { fields = fields, format = opts.format }
				done(true)
			end,
		}
		require(editor_name).edit({ key = "42", project = "Platform", type = { name = "Task" } }, function() end)
		content.title = "Updated title"
		options.submit(handle)
		assert.same({ fields = { ["System.Title"] = "Updated title" }, format = "html" }, saved)
	end)
end)
