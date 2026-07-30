local M = {}

local keymaps = require("atlas.core.keymaps")

---@class AtlasDiffKeymapActions
---@field close fun()
---@field select_file fun()

---@param session AtlasNativeDiffSession
---@param actions AtlasDiffKeymapActions
function M.register(session, actions)
	local close_keys = keymaps.resolve("ui.close") or {}
	for _, buf in ipairs({ session.panel.buf, session.content.buf }) do
		for _, key in ipairs(close_keys) do
			vim.keymap.set("n", key, actions.close, {
				buffer = buf,
				silent = true,
				nowait = true,
				desc = "Close diff",
			})
		end
	end
	for _, key in ipairs({ "<CR>", "l" }) do
		vim.keymap.set("n", key, actions.select_file, {
			buffer = session.panel.buf,
			silent = true,
			nowait = true,
			desc = "Open changed file",
		})
	end
end

return M
