local M = {}

local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")
local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")

---@type table<AtlasRelationship, string>
local relationship_highlights = {
	closes = "AtlasTextPositive",
	["closed by"] = "AtlasTextPositive",
	blocks = "AtlasTextWarning",
	["blocked by"] = "AtlasTextWarning",
	["is blocked by"] = "AtlasTextWarning",
	parent = "AtlasLogInfo",
	["sub-issue"] = "AtlasLogInfo",
	child = "AtlasLogInfo",
}

---@class AtlasDetailLinks
---@field items AtlasRelatedItem[]
---@field loading boolean
---@field error string|nil

local function clean(value)
	return tostring(value or ""):gsub("[%c]", " ")
end

---@param state IssuesDetailState|PullsDetailState
function M.reset(state)
	state.links = { items = {}, loading = false }
end

---@param state IssuesDetailState|PullsDetailState
---@param entity Issue|PullRequest
---@param force_refresh boolean
---@param refresh fun()
function M.load(state, entity, force_refresh, refresh)
	M.reset(state)
	local core = state.provider and state.provider.capabilities.core
	if not core or not core.fetch_links then
		return
	end
	local current = state.links
	current.loading = true
	state.requests.run(function(done)
		return core.fetch_links(entity, { force_refresh = force_refresh }, done)
	end, function(items, err)
		if state.links ~= current then
			return
		end
		current.items = items or {}
		current.error = err
		current.loading = false
		refresh()
	end)
end

---@param state IssuesDetailState|PullsDetailState
---@param kind "issue"|"pr"|nil
---@return AtlasRelatedItem[]
function M.items(state, kind)
	local result, seen = {}, {}
	local source = vim.list_extend({}, state.links and state.links.items or {})
	local pr = state.current_pr
	if pr then
		local jira = require("atlas.providers.jira.links")
		vim.list_extend(source, jira.resolve(pr.title, pr.source and pr.source.branch))
	end
	for _, link in ipairs(source) do
		local key = tostring(link.url or "") .. "\n" .. tostring(link.relationship or "")
		if link.url and link.url ~= "" and not seen[key] and (kind == nil or link.kind == kind) then
			seen[key] = true
			table.insert(result, link)
		end
	end
	return result
end

---@param link AtlasRelatedItem
---@return string
---@return AtlasPickerChunk[]|nil
function M.label(link)
	local icon
	if link.kind == "pr" then
		icon = icons.pulls("pr")
	elseif link.kind == "issue" then
		icon = icons.issues("issue")
	else
		icon = icons.action("open_in_browser")
	end
	local relationship = clean(link.relationship)
	local title = clean(link.title)
	if title == "" then
		title = clean(link.key or link.url)
	end
	local text = icon .. (title ~= "" and " " .. title or "")
	if relationship == "" then
		return text
	end
	return relationship .. " " .. text,
		{
			{ relationship, relationship_highlights[vim.trim(relationship):lower()] or "AtlasTextMuted" },
			{ " " .. text },
		}
end

---@param link AtlasRelatedItem
---@param browser boolean|nil
function M.open(link, browser)
	if not link or type(link.url) ~= "string" or not link.url:match("^https?://") then
		return
	end
	local target = require("atlas.providers").resolve(link.url)
	if
		not browser
		and link.kind ~= "external"
		and target
		and (target.entity == "issue" or target.entity == "pr")
		and require("atlas.config").provider_options(target.provider) ~= nil
	then
		require("atlas.commands.open").open(link.url)
	else
		vim.ui.open(link.url)
	end
end

local function clean_preview(value)
	return vim.trim((json.safe_str(value) or ""):gsub("[%c]", " "))
end

local function first(...)
	for index = 1, select("#", ...) do
		local value = clean_preview(select(index, ...))
		if value ~= "" then
			return value
		end
	end
	return ""
end

local function user_name(value)
	local user = json.safe_table(value)
	local username = clean_preview(user.username)
	return first(user.name, username ~= "" and "@" .. username or nil)
end

local function names(values, format)
	local result = {}
	for _, value in ipairs(json.safe_table(values)) do
		local name = format(value)
		if name ~= "" then
			table.insert(result, name)
		end
	end
	return table.concat(result, ", ")
end

---@param link AtlasRelatedItem
---@param target AtlasTarget|nil
---@param values table|nil
---@param errors table|nil
---@return AtlasPickerPreview
local function render_preview(link, target, values, errors)
	target, values, errors = target or {}, values or {}, errors or {}
	local entity = json.safe_table(json.safe_table(values.entity)[1])
	local details = json.safe_table(values.details)
	local kind = target.entity or link.kind
	local key = first(entity.key, link.key, target.issue_key, target.id and "#" .. target.id)
	local title = first(entity.title, details.title, link.title, key, "Linked item")
	local lines = { "# " .. title, "" }
	local function field(label, value)
		value = clean_preview(value)
		if value ~= "" then
			table.insert(lines, "**" .. label .. ":** " .. value)
		end
	end
	field(kind == "pr" and "Pull request" or kind == "issue" and "Issue" or "Link", key)
	field("Repository", first(entity.repo_full_name, target.repo_full_name, target.project_path))
	field("Relationship", link.relationship)
	field("Status", first(entity.status, entity.state, details.status))
	field(
		kind == "pr" and "Author" or "Reporter",
		first(user_name(entity.author), user_name(entity.reporter), user_name(details.reporter))
	)
	field("Assignees", first(names(details.assignees, user_name), user_name(entity.assignee)))
	local source, destination =
		clean_preview(json.safe_table(entity.source).branch), clean_preview(json.safe_table(entity.destination).branch)
	if source ~= "" and destination ~= "" then
		field("Branches", source .. " → " .. destination)
	end
	field(
		"Labels",
		names(details.labels, function(label)
			return clean_preview(type(label) == "string" and label or json.safe_table(label).name)
		end)
	)
	field("URL", link.url)
	for _, entry in ipairs({ { "entity", "Item" }, { "details", "Description" } }) do
		if errors[entry[1]] then
			table.insert(lines, "")
			table.insert(lines, "> " .. entry[2] .. " unavailable: " .. clean_preview(errors[entry[1]]))
		end
	end
	if json.nilify(values.details) ~= nil then
		local description = utils.normalize_newlines(json.safe_str(details.description) or "")
		description = vim.trim(description:gsub("[%z\1-\8\11\12\14-\31\127]", ""))
		vim.list_extend(lines, { "", "## Description", "" })
		vim.list_extend(lines, vim.split(description ~= "" and description or "No description", "\n", { plain = true }))
	end
	return { title = key ~= "" and key or title, lines = lines }
end

---Create a preview loader with a cache that lasts only for this picker.
---@return AtlasPickerPreviewItem
local function new_preview()
	local cache = {}
	return function(link, done)
		local providers = require("atlas.providers")
		local target = providers.resolve(link.url)
		if
			link.kind == "external"
			or not target
			or (target.entity ~= "issue" and target.entity ~= "pr")
			or require("atlas.config").provider_options(target.provider) == nil
		then
			done(render_preview(link, target))
			return nil
		end
		local provider = providers.load(target.provider, target.domain)
		if not provider then
			done(render_preview(link, target))
			return nil
		end
		local url = target.url or link.url
		if cache[url] then
			done(render_preview(link, target, cache[url]))
			return nil
		end
		local ref
		if target.entity == "issue" then
			ref = provider.issue_ref(target)
		elseif target.id and target.repo_full_name then
			ref = { id = target.id, repo_full_name = target.repo_full_name }
		end
		if not ref then
			done(render_preview(link, target, nil, { entity = "Could not determine item reference" }))
			return nil
		end
		local core = provider.capabilities.core
		local fetch_details = target.entity == "issue" and core.fetch_issue or core.fetch_pullrequest
		local requests = request_scope.new()
		requests.all({
			entity = function(callback)
				return core.fetch_by_refs({ ref }, { force_refresh = false }, callback)
			end,
			details = function(callback)
				return fetch_details(ref, { force_refresh = false }, callback)
			end,
		}, function(values, errors)
			if not json.safe_table(values.entity)[1] and not errors.entity then
				errors.entity = "Item not found"
			end
			if json.nilify(values.details) == nil and not errors.details then
				errors.details = "No details returned"
			end
			if next(errors) == nil then
				cache[url] = values
			end
			done(render_preview(link, target, values, errors))
		end)
		return requests
	end
end

---@param state IssuesDetailState|PullsDetailState
---@param kind "issue"|"pr"|nil
---@param browser boolean|nil
function M.select(state, kind, browser)
	local items, seen = {}, {}
	for _, link in ipairs(M.items(state, kind)) do
		if not seen[link.url] then
			seen[link.url] = true
			table.insert(items, link)
		end
	end
	if #items == 0 then
		local message = state.links and state.links.loading and "Loading links..."
			or state.links and state.links.error and ("Links unavailable: " .. state.links.error)
			or "No matching links"
		require("atlas.core.notify").info(message)
	else
		require("atlas.ui.picker").select_with_preview({
			title = kind == "pr" and "Linked pull requests" or kind == "issue" and "Linked issues" or "Links",
			items = items,
			key = function(link)
				return link.url
			end,
			format_item = M.label,
			preview_item = new_preview(),
			on_select = function(link)
				if link then
					M.open(link, browser)
				end
			end,
		})
	end
end

---@param state IssuesDetailState|PullsDetailState
---@return { label: string, icon: string, callback: fun() }
function M.action(state)
	return {
		label = "Open related items",
		icon = icons.general("link"),
		callback = function()
			M.select(state)
		end,
	}
end

---@param state IssuesDetailState|PullsDetailState
---@return table[]
function M.keymaps(state)
	local keys = require("atlas.core.keymaps").resolve("ui.open_references")
	if not keys then
		return {}
	end
	return {
		{
			key = #keys == 1 and keys[1] or keys,
			desc = "Open references",
			opts = { nowait = true, silent = true },
			callback = function()
				M.select(state)
			end,
		},
	}
end

---@param state IssuesDetailState|PullsDetailState
---@return IssuesDetailChip[]
function M.chips(state)
	local items = M.items(state)
	local counts = { issue = 0, pr = 0, external = 0 }
	local seen = {}
	for _, link in ipairs(items) do
		if not seen[link.url] then
			seen[link.url] = true
			counts[link.kind] = (counts[link.kind] or 0) + 1
		end
	end
	local chips = {}
	local icon = icons.general("link")
	for _, entry in ipairs({ { "issue", "issue" }, { "pr", "PR" }, { "external", "link" } }) do
		if counts[entry[1]] > 0 then
			local count = counts[entry[1]]
			table.insert(chips, {
				label = icon .. " " .. count .. " " .. entry[2] .. (count == 1 and "" or "s"),
				hl = "AtlasRelatedChip",
			})
		end
	end
	return chips
end

return M
