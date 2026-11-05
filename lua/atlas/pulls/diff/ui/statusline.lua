local components = require("atlas.ui.statusline.components")
local diff_keymaps = require("atlas.pulls.diff.keymaps")
local icons = require("atlas.ui.shared.icons")
local review_actions = require("atlas.pulls.actions.review")

local M = {}
local review_progress = { "󰝦", "󰪞", "󰪟", "󰪠", "󰪡", "󰪢", "󰪣", "󰪤", "󰪥" }

---@param viewer AtlasDiffViewer
---@return AtlasStatuslineLayout
function M.layout(viewer)
	local session = viewer.session

	local function title()
		local pr = session.source.pr
		return pr and string.format("#%s %s", pr.id, pr.title)
			or string.format("%s...%s", session.range.base_revision:sub(1, 8), session.range.head_revision:sub(1, 8))
	end

	local function progress()
		local commits = session:shown_commits()
		if commits then
			local newest, oldest = 0, 0
			for index, commit in ipairs(session.commits) do
				local position = #session.commits - index + 1
				if commit == commits[1] then
					newest = position
				end
				if commit == commits[#commits] then
					oldest = position
				end
			end
			return {
				text = #commits == 1
						and string.format("Commit %d/%d %s", newest, #session.commits, commits[1].hash:sub(1, 8))
					or string.format(
						"Commits %d-%d/%d %s..%s",
						oldest,
						newest,
						#session.commits,
						commits[#commits].hash:sub(1, 8),
						commits[1].hash:sub(1, 8)
					),
				hl_group = "AtlasFooterWarning",
			}
		end

		local reviewed_files = session.review_context and session.review_context.reviewed_files
		local files = viewer.explorer.files
		if not reviewed_files or #files == 0 then
			return nil
		end

		local count = 0
		for _, file in ipairs(files) do
			if reviewed_files[file.path] then
				count = count + 1
			end
		end

		return {
			text = string.format("%s %d/%d", review_progress[math.ceil(count / #files * 8) + 1], count, #files),
			hl_group = count == #files and "AtlasFooterSuccess" or "AtlasFooterInfo",
		}
	end

	local function lsp()
		local client = vim.lsp.get_clients({ bufnr = viewer.renderer.right.buf })[1]
		if client then
			return {
				text = string.format("%s %s", icons.get("lsp"), client.name),
				hl_group = "AtlasFooterInfo",
			}
		end
	end

	local function comments()
		local threads = review_actions.group_comments(session.review and session.review.comments or {})
		if #threads == 0 then
			return nil
		end

		local unresolved = #vim.tbl_filter(function(thread)
			return thread.comment.state ~= "RESOLVED"
		end, threads)

		return {
			text = string.format("%s %d/%d", icons.get("comment"), unresolved, #threads),
			hl_group = "AtlasFooterInfo",
		}
	end

	local function notes()
		local items = session.notes and session.notes.items or {}
		if #items > 0 then
			return {
				text = string.format("%s %d", icons.get("pin"), #items),
				hl_group = "AtlasFooterNote",
			}
		end
	end

	local function pending()
		local review = session.review
		local count = 0
		for _, comment in ipairs(review and review.comments or {}) do
			if comment.pending and not comment.deleted then
				count = count + 1
			end
		end

		if count == 0 and not (review and review.review.pending) then
			return nil
		end

		return {
			text = icons.get("inprogress", "status")
				.. " "
				.. (count > 0 and string.format("%d pending", count) or "Pending review"),
			hl_group = "AtlasFooterWarning",
		}
	end

	local function hints(ctx)
		return components.hints(ctx.buf, diff_keymaps.hints(viewer, ctx.buf))
	end

	return { title, progress, hints, "%=", lsp, comments, notes, pending, components.help }
end

return M
