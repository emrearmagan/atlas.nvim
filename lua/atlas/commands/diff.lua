local diff = require("atlas.pulls.diff")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")

local M = {}
local completion = {}

vim.api.nvim_create_autocmd("CmdlineLeave", {
	group = vim.api.nvim_create_augroup("AtlasCommandCompletion", { clear = true }),
	pattern = ":",
	callback = function()
		completion = {}
	end,
})

---@param arglead string
---@param args string[]|nil
---@return string[]
function M.complete(arglead, args)
	if args and #args > 1 then
		return {}
	end

	local cwd = git.default_cwd()
	if completion.cwd ~= cwd then
		local res = vim.system({
			"git",
			"for-each-ref",
			"--format=%(refname:short)",
			"refs/heads",
			"refs/remotes",
		}, { cwd = cwd, text = true }):wait()

		completion = { cwd = cwd, refs = {} }
		if res.code == 0 then
			completion.refs = { "HEAD" }
			vim.list_extend(completion.refs, vim.split(res.stdout, "\n", { plain = true, trimempty = true }))
		end
	end

	local separator = arglead:find("...", 1, true)
	local range = separator and arglead:sub(1, separator + 2) or ""
	local prefix = arglead:sub(#range + 1)
	local matches = {}
	for _, ref in ipairs(completion.refs) do
		if ref:find(prefix, 1, true) == 1 then
			table.insert(matches, range .. ref)
		end
	end
	return matches
end

---@param value string
function M.open(value)
	local base, head = value:match("^(.-)%.%.%.(.*)$")
	base, head = vim.trim(base or ""), vim.trim(head or "")
	if base == "" or head == "" then
		notify.error("Expected a range like base...head", { vim_notify = true })
		return
	end
	diff.open_range({ base = base, head = head }, function(open_err)
		if open_err then
			notify.error(open_err, { vim_notify = true })
		end
	end)
end

return M
