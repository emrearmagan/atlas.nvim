local M = {}

local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local markdown = require("atlas.formats.markdown")
local editor = require("atlas.ui.popups.editor")
local notify = require("atlas.core.notify")
local detail = require("atlas.issues.ui.detail.state")
local conversation = require("atlas.issues.ui.detail.tabs.conversation.state")

local view_mode = "markdown"

---@param _issue Issue
---@param details IssueDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_issue, details, width)
	if details == nil then
		return {}, {}, {}
	end

	local lines = {}
	local spans = {}
	local content_width = math.max(1, width - 2)

	local description = details.description or ""
	if description == "" then
		utils.push(lines, spans, "No description", "AtlasTextMuted")
	elseif view_mode == "raw" then
		for _, line in ipairs(vim.split(utils.normalize_newlines(description), "\n", { plain = true })) do
			utils.push(lines, spans, line)
		end
	else
		local content = markdown.render(description, { width = width, padding = 1 })
		return content.lines, content.highlights, {}
	end

	local content = utils.wrap_content({ lines = lines, highlights = spans }, content_width, " ")
	return content.lines, content.highlights, {}
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	local toggle_keys = keymaps.resolve("ui.toggle_description_mode")
	if toggle_keys then
		help.register("Detail", {
			{
				key = #toggle_keys == 1 and toggle_keys[1] or toggle_keys,
				desc = "Toggle description mode",
				index = 10,
				opts = { nowait = true, silent = true },
				callback = function()
					view_mode = view_mode == "raw" and "markdown" or "raw"
					refresh()
				end,
			},
		}, { index = 212, buffer = buf })
	end

	local provider = detail.provider
	local core = provider and provider.capabilities.core
	local update_description = core and core.update_description
	local comments = provider and provider.capabilities.comments
	local keys = update_description and keymaps.resolve("ui.comments.edit") or nil
	if keys == nil then
		return
	end

	help.register("Detail", {
		{
			key = #keys == 1 and keys[1] or keys,
			desc = "Edit description",
			index = 20,
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = detail.current_issue
				local details = detail.current_details
				if issue == nil or details == nil then
					return
				end

				local completion
				if comments and comments.comment_completion then
					completion = comments.comment_completion({
						issue = issue,
						details = details,
						comments = conversation.comments(),
					})
				end

				local current = tostring(details.description or "")
				editor.open({
					key = "issue-description-edit-" .. tostring(issue.key),
					title = " Edit Description ",
					width_ratio = 0.5,
					height_ratio = 0.18,
					initial_text = current,
					completion = completion,
					on_save = function(text)
						local updated = text or ""
						if updated == current then
							notify.info("Description unchanged", { timeout = 1200 })
							return
						end
						notify.loading("Updating description...")
						update_description(issue, updated, function(ok, err)
							local selected = detail.current_issue
							if selected == nil or tostring(selected.key) ~= tostring(issue.key) then
								return
							end
							if not ok then
								notify.error("Description update failed: " .. tostring(err or "Unknown error"))
								return
							end
							details.description = updated
							notify.success("Description updated", { timeout = 1200 })
							refresh()
						end)
					end,
				})
			end,
		},
	}, { index = 212, buffer = buf })
end

---@param buf integer
function M.deactivate(buf)
	for _, action in ipairs({ "ui.toggle_description_mode", "ui.comments.edit" }) do
		local keys = keymaps.resolve(action)
		if keys then
			help.remove("Detail", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })
		end
	end
end

return M
