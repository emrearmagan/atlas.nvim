local git = require("atlas.core.git")
local notify = require("atlas.core.notify")

local M = {}

---@param target string|nil A pull request URL or reference, "." for the current repository, or nil for all notes.
function M.open(target)
	local ui = require("atlas.pulls.notes.ui")
	if not target then
		ui.open()
		return
	end
	if target ~= "." then
		local pr, err = require("atlas.pulls.notes").resolve_target(target)
		if not pr then
			notify.error(err or "Expected a pull request URL or canonical reference", { vim_notify = true })
			return
		end
		ui.open(pr)
		return
	end

	git.local_repository(nil, function(repository)
		if not repository then
			notify.warn("No supported Git repository found", { vim_notify = true })
			ui.open()
			return
		end
		ui.open({ host = repository.host, repository = repository.repo_full_name })
	end)
end

return M
