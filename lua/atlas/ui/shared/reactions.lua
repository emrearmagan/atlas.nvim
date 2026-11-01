local emojis = require("atlas.ui.shared.emojis")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")

local M = {}

---@param reactions AtlasReaction[]|nil
---@return string text, table[] spans
function M.format(reactions)
	local parts, spans = {}, {}
	local col = 0
	for _, reaction in ipairs(reactions or {}) do
		if #parts > 0 then
			col = col + 2
		end
		local icon = emojis.get(reaction.name)
		local count = " " .. reaction.count
		spans[#spans + 1] = { line = 0, start_col = col, end_col = col + #icon, hl_group = "AtlasLogInfo" }
		spans[#spans + 1] =
			{ line = 0, start_col = col + #icon, end_col = col + #icon + #count, hl_group = "AtlasTextMuted" }
		col = col + #icon + #count
		parts[#parts + 1] = icon .. count
	end
	return table.concat(parts, "  "), spans
end

---@param reactions AtlasReaction[]|nil
---@param name string
---@return AtlasReaction|nil
local function find(reactions, name)
	for _, reaction in ipairs(reactions or {}) do
		if reaction.name == name then
			return reaction
		end
	end
end

---@param reaction AtlasReaction
---@return string
local function reactors(reaction)
	local names = {}
	for index = 1, math.min(3, #(reaction.users or {})) do
		local user = reaction.users[index]
		names[index] = user.username or user.name
	end
	if #names == 0 then
		return string.format("by %d %s", reaction.count, reaction.count == 1 and "user" or "users")
	end
	local more = reaction.count - #names
	return "by " .. table.concat(names, ", ") .. (more > 0 and " +" .. more or "")
end

---Reactions the comment already has come first, then the provider's other options.
---@param comment IssueComment|PullsComment|GitHubDiscussionComment
---@param options AtlasReactionOption[]
---@return AtlasReactionOption[]
local function picker_items(comment, options)
	local by_name, items, listed = {}, {}, {}
	for _, option in ipairs(options) do
		by_name[option.name] = option
	end
	for _, reaction in ipairs(comment.reactions or {}) do
		table.insert(items, by_name[reaction.name] or { name = reaction.name })
		listed[reaction.name] = true
	end
	for _, option in ipairs(options) do
		if not listed[option.name] then
			table.insert(items, option)
		end
	end
	return items
end

---@param option AtlasReactionOption
---@param reaction AtlasReaction|nil
---@param width integer
---@return string, AtlasPickerChunk[]
local function picker_line(option, reaction, width)
	local icon = emojis.get(option.name)
	if not reaction then
		return icon .. " " .. option.name, { { icon, "AtlasLogInfo" }, { " " .. option.name, "Normal" } }
	end
	local name = string.format(" %-" .. width .. "s", option.name)
	local details = " " .. reactors(reaction) .. (reaction.reacted and " (you)" or "")
	return icon .. name .. details, { { icon, "AtlasLogInfo" }, { name, "Normal" }, { details, "AtlasTextMuted" } }
end

---@param comment IssueComment|PullsComment|GitHubDiscussionComment
---@param name string
local function increment(comment, name)
	local reaction = find(comment.reactions, name)
	if reaction then
		reaction.count = reaction.count + 1
		reaction.reacted = true
	else
		comment.reactions = comment.reactions or {}
		table.insert(comment.reactions, { name = name, count = 1, reacted = true })
	end
end

---@param comment IssueComment|PullsComment|GitHubDiscussionComment
---@param name string
local function decrement(comment, name)
	for index, reaction in ipairs(comment.reactions or {}) do
		if reaction.name == name then
			reaction.count = reaction.count - 1
			reaction.reacted = false
			if reaction.count <= 0 then
				table.remove(comment.reactions, index)
			end
			return
		end
	end
end

---Picking one of your own reactions removes it; any other adds it.
---@param capability AtlasReactionsCapability
---@param target Issue|PullRequest|GitHubDiscussionDetails
---@param comment IssueComment|PullsComment|GitHubDiscussionComment
---@param is_current fun(): boolean
---@param on_changed fun()
function M.pick(capability, target, comment, is_current, on_changed)
	local width = 0
	for _, reaction in ipairs(comment.reactions or {}) do
		width = math.max(width, #reaction.name)
	end
	picker.select({
		title = "React",
		items = picker_items(comment, capability.options),
		size = { width = 0.3, height = 0.3 },
		format_item = function(option)
			return picker_line(option, find(comment.reactions, option.name), width)
		end,
		on_select = function(option)
			if option == nil then
				return
			end
			local reaction = find(comment.reactions, option.name)
			local remove = reaction and reaction.reacted and capability.remove
			notify.loading(remove and "Removing reaction..." or "Adding reaction...")
			local request = remove or capability.add
			request(target, comment, option.key or option.name, function(_, err)
				if not is_current() then
					return
				end
				if err then
					notify.error("Reaction failed: " .. tostring(err))
					return
				end
				if remove then
					decrement(comment, option.name)
				else
					increment(comment, option.name)
				end
				notify.success(remove and "Reaction removed" or "Reaction added", { timeout = 1200 })
				on_changed()
			end)
		end,
	})
end

return M
