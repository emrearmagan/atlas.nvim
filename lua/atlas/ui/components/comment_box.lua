local M = {}

---@class CommentBoxSection
---@field lines string[]
---@field spans table[]

---@class CommentBoxReactions
---@field text string
---@field spans table[]

---@class CommentBoxOpts
---@field author string
---@field author_hl string|nil
---@field icon string|nil
---@field verb string|nil
---@field timestamp string|nil
---@field actions_text string|nil
---@field actions_hl string|nil
---@field body_lines string[]|nil
---@field body_hl string|nil
---@field reactions CommentBoxReactions|nil
---@field additional string|nil
---@field additional_hl string|nil
---@field width integer

---@param opts CommentBoxOpts
---@return CommentBoxSection
local function render_header(opts)
	local spans = {}
	local icon = opts.icon or ""
	local author = opts.author or "Unknown"
	local verb = opts.verb or ""
	local timestamp = opts.timestamp or ""
	local author_hl = opts.author_hl or "AtlasTextMuted"
	local actions_hl = opts.actions_hl or "AtlasTextMuted"
	local width = opts.width or 80

	local left_parts = {}
	local col = 0
	if icon ~= "" then
		table.insert(left_parts, icon)
		table.insert(spans, { line = 0, start_col = col, end_col = col + #icon, hl_group = author_hl })
		col = col + #icon
		table.insert(left_parts, "  ")
		col = col + 2
	end
	table.insert(left_parts, author)
	table.insert(spans, { line = 0, start_col = col, end_col = col + #author, hl_group = author_hl })
	col = col + #author

	if verb ~= "" or timestamp ~= "" then
		table.insert(left_parts, "  ")
		col = col + 2
		local rest
		if verb ~= "" and timestamp ~= "" then
			rest = verb .. "  " .. timestamp
		else
			rest = verb ~= "" and verb or timestamp
		end
		table.insert(left_parts, rest)
		table.insert(spans, { line = 0, start_col = col, end_col = col + #rest, hl_group = "AtlasTextMuted" })
		col = col + #rest
	end

	local left = table.concat(left_parts, "")
	local actions_text = opts.actions_text or ""
	local header_line
	if actions_text ~= "" then
		local gap = math.max(2, width - vim.api.nvim_strwidth(left) - vim.api.nvim_strwidth(actions_text))
		header_line = left .. string.rep(" ", gap) .. actions_text
		local actions_start = #left + gap
		table.insert(spans, {
			line = 0,
			start_col = actions_start,
			end_col = actions_start + #actions_text,
			hl_group = actions_hl,
		})
	else
		header_line = left
	end

	return { lines = { header_line }, spans = spans }
end

---@param opts CommentBoxOpts
---@return CommentBoxSection
local function render_body(opts)
	local lines, spans = {}, {}

	for _, bl in ipairs(opts.body_lines or {}) do
		table.insert(lines, bl)
		if opts.body_hl then
			table.insert(spans, {
				line = #lines - 1,
				start_col = 0,
				end_col = #bl,
				hl_group = opts.body_hl,
			})
		end
	end

	if opts.reactions and opts.reactions.text and opts.reactions.text ~= "" then
		table.insert(lines, opts.reactions.text)
		local idx = #lines - 1
		for _, s in ipairs(opts.reactions.spans or {}) do
			table.insert(spans, {
				line = idx,
				start_col = s.start_col,
				end_col = s.end_col,
				hl_group = s.hl_group,
			})
		end
	end

	if opts.additional and opts.additional ~= "" then
		table.insert(lines, opts.additional)
		table.insert(spans, {
			line = #lines - 1,
			start_col = 0,
			end_col = #opts.additional,
			hl_group = opts.additional_hl or "AtlasTextMuted",
		})
	end

	return { lines = lines, spans = spans }
end

---@param opts CommentBoxOpts
---@return CommentBoxSection header, CommentBoxSection body
function M.render(opts)
	return render_header(opts), render_body(opts)
end

return M
