---@class PullsActivityTab : PullsPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local spinner = require("atlas.ui.components.spinner")
local threads = require("atlas.ui.components.threadsv2")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.pulls.ui.panel.pr.tabs.activity.state")

local PADDING_X = 1

---@type { cancel: fun() }[]
local in_flight = {}

---@return PullsProvider|nil
local function get_provider()
	local pulls_state = require("atlas.pulls.state")
	return pulls_state.provider
end

local function cancel_all()
	for _, handle in ipairs(in_flight) do
		handle.cancel()
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
end

---@param actor {nickname:string?, name:string?}|nil
---@return string
local function actor_name(actor)
	if actor == nil then
		return "Unknown"
	end
	if actor.nickname and actor.nickname ~= "" then
		return actor.nickname
	end
	if actor.name and actor.name ~= "" then
		return actor.name
	end
	return "Unknown"
end

---@param entry PullsActivityEntry
---@return string
local function update_additional(entry)
	local changes = entry.changes or {}

	local keys = {}
	for k, _ in pairs(changes) do
		keys[#keys + 1] = k
	end
	table.sort(keys)

	if #keys == 1 then
		local key = keys[1]
		if key == "description" then
			return "updated description"
		end
		if key == "title" then
			return "updated title"
		end
		if key == "draft" then
			local val = changes.draft
			if type(val) == "table" and val.new == false then
				return "marked as ready"
			end
			return "marked as draft"
		end
		if key == "reviewers" then
			local rev = changes.reviewers or {}
			local added = rev.added or {}
			if #added > 0 then
				local names = {}
				for _, r in ipairs(added) do
					names[#names + 1] = r.display_name or r.nickname or "someone"
				end
				return "added reviewer: " .. table.concat(names, ", ")
			end
			local removed = rev.removed or {}
			if #removed > 0 then
				local names = {}
				for _, r in ipairs(removed) do
					names[#names + 1] = r.display_name or r.nickname or "someone"
				end
				return "removed reviewer: " .. table.concat(names, ", ")
			end
			return "updated reviewers"
		end
	end

	if #keys > 1 then
		return "updated " .. table.concat(keys, ", ")
	end

	-- No explicit changes. fallback to branch info
	local src = entry.source_branch or ""
	local dst = entry.target_branch or ""
	if src ~= "" and dst ~= "" then
		return string.format("updated %s → %s", src, dst)
	end

	return "updated pull request"
end

---@param entries PullsActivityEntry[]
---@return AtlasThreadV2Item[]
local function to_thread_items(entries)
	local items = {}
	for _, e in ipairs(entries) do
		local kind = e.kind
		local author = actor_name(e.actor)
		local timestamp = utils.relative_time(e.date)

		local additional ---@type string|nil
		local content ---@type string|nil
		local entry_icon = icons.general("user")

		if kind == "approval" then
			additional = "approved"
			entry_icon = icons.pulls_status("successful")
			local raw = tostring(e.content_raw or "")
			if raw ~= "" then
				content = raw
			end
		elseif kind == "changes_requested" then
			additional = "requested changes"
			entry_icon = icons.pulls_status("inprogress")
			local raw = tostring(e.content_raw or "")
			if raw ~= "" then
				content = raw
			end
		elseif kind == "review" then
			additional = "left a review"
			entry_icon = icons.pulls("activity")
			local raw = tostring(e.content_raw or "")
			if raw ~= "" then
				content = raw
			end
		elseif kind == "comment" then
			additional = "commented"
			local raw = utils.strip_markup(e.content_raw)
			local first = raw:match("([^\n]+)") or raw
			content = first ~= "" and first or "(empty comment)"

			if e.deleted == true then
				content = "(deleted comment)"
			end
		elseif kind == "update" then
			local raw = type(e.content_raw) == "string" and e.content_raw ~= "" and e.content_raw or nil
			additional = raw or update_additional(e)
			entry_icon = icons.pulls("activity")
		end

		items[#items + 1] = {
			icon = entry_icon,
			author = author,
			right_text = timestamp,
			additional = additional,
			content = content,
			line_map = {
				activity_entry = e,
				activity_actor = e.actor,
			},
		}
	end
	return items
end

---@param item AtlasThreadV2Item
---@param _text string
---@return string|nil
local function additional_hl(item, _text)
	local entry = item.line_map and item.line_map.activity_entry
	if entry == nil then
		return "AtlasTextMuted"
	end
	if entry.kind == "approval" then
		return "AtlasTextPositive"
	end
	if entry.kind == "changes_requested" then
		return "AtlasTextWarning"
	end
	return "AtlasTextMuted"
end

---@param item AtlasThreadV2Item
---@param row string
---@param _row_index integer
---@return table[]|nil
local function content_hl(item, row, _row_index)
	local entry = item.line_map and item.line_map.activity_entry
	if entry == nil then
		return nil
	end

	if entry.kind == "comment" and entry.deleted == true then
		return {
			{ start_col = 0, end_col = #row, hl_group = "AtlasTextMutedStrikethrough" },
		}
	end

	if entry.kind == "update" then
		return {
			{ start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" },
		}
	end

	return nil
end

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, repo, refresh, opts)
	opts = opts or {}

	local provider = get_provider()
	if not provider then
		return
	end

	local force_refresh = opts.force_refresh == true
	local should_fetch = force_refresh
		or state.activity == nil
		or state.activity == "loading"
		or type(state.activity) == "string"

	if should_fetch then
		cancel_all()
		state.reset()
	end

	local pr_id = tostring(pr.id or "")
	if should_fetch and type(provider.fetch_activity) == "function" then
		state.activity = "loading"
		footer.notify("loading", string.format("Loading activity for #%s...", pr_id))
		track(provider.fetch_activity(pr, opts, function(entries, err)
			if err then
				state.activity = err
				footer.notify("error", string.format("Failed to load activity for #%s", pr_id))
			else
				state.activity = entries or {}
				footer.notify("success", string.format("Activity loaded for #%s", pr_id), 1200)
			end
			refresh()
		end))
	end
end

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.activity == nil then
		return lines, spans, line_map
	end

	if state.activity == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading activity..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if type(state.activity) == "string" then
		utils.push(lines, spans, state.activity, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local entries = state.activity
	if #entries == 0 then
		utils.push(lines, spans, "No activity yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local items = to_thread_items(entries)
	local item_lines, item_spans, item_map = threads.render(items, width, {
		padding_x = PADDING_X,
		content_max_lines = 3,
		additional_hl = additional_hl,
		content_hl = content_hl,
		icon_hl_fn = function(item)
			local entry = item.line_map and item.line_map.activity_entry
			if entry and entry.kind == "approval" then
				return "AtlasTextPositive"
			end
			if entry and entry.kind == "changes_requested" then
				return "AtlasTextWarning"
			end
			local author = vim.trim(tostring(item.author or "")):lower()
			return highlights.dynamic_for(author) or "AtlasTextMuted"
		end,
	})

	local offset = #lines
	utils.append_block(lines, spans, { lines = item_lines, highlights = item_spans })
	for lnum, entry in pairs(item_map or {}) do
		line_map[offset + lnum] = entry
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	local k = entry.kind
	return k == "header" or k == "content"
end

function M.deactivate()
	cancel_all()
end

return M
