local layouts = {
	compact = require("atlas.pulls.ui.layouts.compact"),
	plain = require("atlas.pulls.ui.layouts.plain"),
	grouped = require("atlas.pulls.ui.layouts.grouped"),
}

local M = {}

---@param opts table
---@param pulls PullRequest[]
---@return string[], table<integer, table>, table[]
function M.render(opts, pulls)
	local providers = layouts[opts.layout] or layouts.compact
	local render = providers[opts.provider_id] or providers.default

	return render(opts, pulls)
end

return M
