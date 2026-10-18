local keymaps = require("atlas.core.keymaps")
local icons = require("atlas.ui.shared.icons")
local review_actions = require("atlas.pulls.actions.review")

local M = {}
local review_progress = { "󰝦", "󰪞", "󰪟", "󰪠", "󰪡", "󰪢", "󰪣", "󰪤", "󰪥" }

---@param statusline AtlasStatusline
---@param session AtlasDiffSession
---@param files AtlasDiffFile[]
---@param buf integer
function M.update(statusline, session, files, buf)
	local review_data = session.review
	local reviewed_files = session.reviewed_files

	local pr = session.source.pr
	local identity = pr and string.format("#%s %s", pr.id, pr.title)
		or string.format("%s...%s", session.range.base_revision:sub(1, 8), session.range.head_revision:sub(1, 8))
	local items = {
		{ text = identity, hl_group = "AtlasFooterText", priority = 40, min_width = 12 },
	}

	if session:shows_commit() then
		local hash = session.range.head_revision
		local position = 0
		for index, commit in ipairs(session.commits) do
			if commit.hash == hash then
				position = #session.commits - index + 1
			end
		end
		items[#items + 1] = {
			text = string.format("Commit %d/%d %s", position, #session.commits, hash:sub(1, 8)),
			hl_group = "AtlasFooterWarning",
			priority = 45,
		}
	elseif reviewed_files and #files > 0 then
		local count = 0
		for _, file in ipairs(files) do
			if reviewed_files[file.path] then
				count = count + 1
			end
		end
		items[#items + 1] = {
			text = string.format("%s %d/%d", review_progress[math.ceil(count / #files * 8) + 1], count, #files),
			hl_group = count == #files and "AtlasFooterSuccess" or "AtlasFooterInfo",
			priority = 40,
		}
	end

	local client = vim.lsp.get_clients({ bufnr = buf })[1]
	if client then
		items[#items + 1] = {
			text = string.format("%s %s", icons.get("lsp"), client.name),
			hl_group = "AtlasFooterInfo",
			align = "right",
			priority = 10,
		}
	end

	local comments = vim.tbl_filter(function(comment)
		return not comment.deleted
	end, review_data and review_data.comments or {})
	local threads = review_data and review_actions.group_comments(review_data.comments) or {}
	if #threads > 0 then
		local unresolved = #vim.tbl_filter(function(thread)
			return thread.comment.state ~= "RESOLVED"
		end, threads)
		items[#items + 1] = {
			text = string.format("%s %d/%d", icons.get("comment"), unresolved, #threads),
			hl_group = "AtlasFooterInfo",
			align = "right",
			priority = 30,
		}
	end

	local notes = session.notes and session.notes.items or {}
	if #notes > 0 then
		items[#items + 1] = {
			text = string.format("%s %d", icons.get("pin"), #notes),
			hl_group = "AtlasFooterNote",
			align = "right",
			priority = 20,
		}
	end

	local pending_comments = 0
	for _, comment in ipairs(comments) do
		if comment.pending then
			pending_comments = pending_comments + 1
		end
	end

	if pending_comments > 0 or (review_data and review_data.review.pending) then
		items[#items + 1] = {
			text = icons.get("inprogress", "status")
				.. " "
				.. (pending_comments > 0 and string.format("%d pending", pending_comments) or "Pending review"),
			hl_group = "AtlasFooterWarning",
			align = "right",
			priority = 50,
		}
	end

	local help_keys = keymaps.resolve("ui.help")
	statusline.options.help_key = help_keys and help_keys[1] or nil
	statusline:set_items(items)
end

return M
