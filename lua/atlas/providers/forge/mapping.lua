local users = require("atlas.providers.forge.users")

local M = {}

---@type AtlasReactionOption[]
M.reactions = {
	{ name = "thumbsup", key = "+1" },
	{ name = "thumbsdown", key = "-1" },
	{ name = "laughing", key = "laugh" },
	{ name = "tada", key = "hooray" },
	{ name = "confused" },
	{ name = "heart" },
	{ name = "rocket" },
	{ name = "eyes" },
}

---@param username string|nil Comment author.
---@param author_username string|nil Who opened the pull request or issue.
---@param repo_full_name string
---@return string[]|nil
function M.author_roles(username, author_username, repo_full_name)
	if not username then
		return nil
	end

	local roles = {}
	if username:lower() == (author_username or ""):lower() then
		table.insert(roles, "Author")
	end
	if username:lower() == (repo_full_name:match("^([^/]+)/") or ""):lower() then
		table.insert(roles, "Owner")
	end
	return #roles > 0 and roles or nil
end

---@param raw table[] Reactions of one issue, pull request or comment.
---@param username string|nil Current user, to mark their own reactions.
---@return AtlasReaction[]
function M.to_reactions(raw, username)
	local names = {}
	for _, option in ipairs(M.reactions) do
		names[option.key or option.name] = option.name
	end

	local result, by_name = {}, {}
	for _, value in ipairs(raw) do
		local name = names[value.content] or value.content
		local reaction = by_name[name]
		if not reaction then
			reaction = { name = name, count = 0, users = {}, reacted = false }
			by_name[name] = reaction
			table.insert(result, reaction)
		end

		local user = users.to_user(value.user)
		reaction.count = reaction.count + 1
		table.insert(reaction.users, user)
		reaction.reacted = reaction.reacted or (user ~= nil and user.username == username)
	end
	return result
end

return M
