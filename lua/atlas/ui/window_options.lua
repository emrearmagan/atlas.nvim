local M = {}

-- Windows where Atlas disabled 'list', so they can be restored when they show
-- a regular buffer again.
local hidden = {}

---@param buf integer
---@return boolean
local function is_atlas_buffer(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	local name = vim.api.nvim_buf_get_name(buf)
	return name:match("^atlas://") ~= nil or vim.bo[buf].filetype:match("^atlas%-ui%.") ~= nil
end

---@param win integer
---@param value boolean
local function set_list(win, value)
	vim.api.nvim_set_option_value("list", value, { win = win, scope = "local" })
end

---Atlas renders its UI with padding spaces. With 'list' and 'listchars'
---enabled globally, those spaces would render as `·` markers in titles and
---other components, so hide listchars in Atlas windows.
function M.setup()
	local group = vim.api.nvim_create_augroup("AtlasWindowOptions", { clear = true })
	hidden = {}

	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
		group = group,
		callback = function(args)
			local buf = args.buf
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end

			local atlas = is_atlas_buffer(buf)
			for _, win in ipairs(vim.fn.win_findbuf(buf)) do
				if atlas then
					hidden[win] = true
					set_list(win, false)
				elseif hidden[win] then
					hidden[win] = nil
					set_list(win, vim.api.nvim_get_option_value("list", { scope = "global" }))
				end
			end
		end,
		desc = "Hide listchars in Atlas UI windows",
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(args)
			hidden[tonumber(args.match)] = nil
		end,
	})
end

return M
