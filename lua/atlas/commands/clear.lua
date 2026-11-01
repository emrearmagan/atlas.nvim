local notify = require("atlas.core.notify")

local M = {}

local function clear_caches()
	require("atlas.core.cache").clear_all()
	require("atlas.core.memory_cache").clear_all()
end

---@param prompt string
---@param on_confirm fun()
local function confirm(prompt, on_confirm)
	vim.ui.input({ prompt = prompt }, function(answer)
		answer = vim.trim(tostring(answer or "")):lower()
		if answer == "y" or answer == "yes" then
			on_confirm()
		end
	end)
end

---@param target string|nil
---@return boolean|nil
function M.run(target)
	if target == "cache" then
		confirm("Delete Atlas caches and cloned repositories? [y/N]: ", function()
			clear_caches()
			notify.info("Atlas caches cleared", { vim_notify = true })
		end)
		return
	end
	if target == "notes" then
		require("atlas.pulls.notes.ui").clear_all()
		return
	end
	if target == "reviewed" then
		confirm("Delete reviewed file marks? [y/N]: ", function()
			local cleared, err = require("atlas.pulls.reviewed").clear_all()
			if not cleared then
				notify.error(err or "Unable to delete reviewed file marks", { vim_notify = true })
				return
			end
			notify.info("Reviewed file marks deleted", { vim_notify = true })
		end)
		return
	end
	if target == "stars" then
		confirm("Delete all starred items? [y/N]: ", function()
			local cleared, err = require("atlas.core.starred").clear_all()
			if not cleared then
				notify.error(err or "Unable to delete starred items", { vim_notify = true })
				return
			end
			notify.info("Starred items deleted", { vim_notify = true })
		end)
		return
	end
	if target then
		return false
	end

	confirm("Delete Atlas caches, clones, notes, reviewed file marks, stars, and logs? [y/N]: ", function()
		local cleared, err = require("atlas.pulls.notes").clear_all()
		if not cleared then
			notify.error(err or "Unable to delete notes", { vim_notify = true })
			return
		end
		local reviewed_cleared, reviewed_err = require("atlas.pulls.reviewed").clear_all()
		if not reviewed_cleared then
			notify.error(reviewed_err or "Unable to delete reviewed file marks", { vim_notify = true })
			return
		end
		local stars_cleared, stars_err = require("atlas.core.starred").clear_all()
		if not stars_cleared then
			notify.error(stars_err or "Unable to delete starred items", { vim_notify = true })
			return
		end
		clear_caches()
		require("atlas.core.logger").clear()
		local notes_ui = package.loaded["atlas.pulls.notes.ui"]
		if notes_ui then
			notes_ui.refresh()
		end
		notify.info("Atlas data cleared", { vim_notify = true })
	end)
end

return M
