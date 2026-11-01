local M = {}

local logger = require("atlas.core.logger")

---@param text string
---@param format string|nil
---@param on_done fun(text: string, format: string)
---@return { cancel: fun() }|nil
function M.to_markdown(text, format, on_done)
	format = (format or "html"):lower()
	if format ~= "html" or vim.fn.executable("pandoc") ~= 1 then
		on_done(text, format)
		return nil
	end

	local cancelled = false
	local process = vim.system(
		{ "pandoc", "--from=html", "--to=gfm-raw_html", "--wrap=none" },
		{ stdin = text, text = true },
		vim.schedule_wrap(function(result)
			if cancelled then
				return
			end
			if result.code ~= 0 then
				logger.logerror("Pandoc HTML conversion failed", { error = result.stderr })
				on_done(text, format)
				return
			end
			on_done(result.stdout or "", "markdown")
		end)
	)
	return {
		cancel = function()
			cancelled = true
			process:kill(15)
		end,
	}
end

return M
