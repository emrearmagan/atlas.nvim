local M = {}

local json = require("atlas.core.json")

---@type AtlasReactionOption[]
M.reactions = {
	{ name = "thumbsup" },
	{ name = "thumbsdown" },
	{ name = "laughing" },
	{ name = "tada" },
	{ name = "confused" },
	{ name = "heart" },
	{ name = "rocket" },
	{ name = "eyes" },
}

---@param raw any
---@return AtlasUser|nil
function M.to_user(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local username = json.safe_str(raw.username) or ""
	if username == "" then
		return nil
	end
	local name = json.safe_str(raw.name) or ""
	local id = json.safe_str(raw.id) or ""
	return {
		id = id:match("([^/]+)$") or id,
		name = name ~= "" and name or username,
		username = username,
	}
end

---@param awards any GraphQL `awardEmoji.nodes`, one per user
---@param viewer string|nil Username of the current user
---@return AtlasReaction[]
function M.award_reactions(awards, viewer)
	local reactions, by_name = {}, {}
	for _, award in ipairs(json.safe_table(awards)) do
		local name = type(award) == "table" and json.safe_str(award.name) or nil
		if name and name ~= "" then
			local reaction = by_name[name]
			if not reaction then
				reaction = { name = name, count = 0, users = {}, reacted = false }
				by_name[name] = reaction
				table.insert(reactions, reaction)
			end
			reaction.count = reaction.count + 1
			local user = M.to_user(award.user)
			if user then
				table.insert(reaction.users, user)
				reaction.reacted = reaction.reacted or user.username == viewer
			end
		end
	end
	return reactions
end

---@param note any
---@param author_username string|nil
---@return string[]|nil
function M.author_roles(note, author_username)
	note = json.safe_table(note)
	local author = json.safe_table(note.author)
	local roles = {}
	if author.username ~= nil and author.username == author_username then
		table.insert(roles, "Author")
	end
	if author.bot == true then
		table.insert(roles, "Bot")
	end
	local level = json.safe_str(note.maxAccessLevelOfAuthor)
	if level then
		table.insert(roles, level)
	end
	if note.authorIsContributor == true then
		table.insert(roles, "Contributor")
	end
	return #roles > 0 and roles or nil
end

---@param id any A notes GraphQL gid or REST id
---@return string|nil
function M.note_id(id)
	-- Note gids carry the notes class (Note, DiscussionNote, DiffNote), which changes when a note gets a reply.
	local number = tostring(json.nilify(id) or ""):match("(%d+)$")
	return number and "gid://gitlab/Note/" .. number or nil
end

return M
