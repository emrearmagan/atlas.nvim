local M = {}

---@param text string|nil
---@return number
function M.text_width(text)
	return vim.fn.strdisplaywidth(text or "")
end

---@param text string
---@param width integer
---@return string padded_text
---@return integer left_pad
function M.center_text(text, width)
	local content_width = vim.fn.strdisplaywidth(text)
	if content_width >= width then
		return text, 0
	end
	local left_pad = math.floor((width - content_width) / 2)
	return string.rep(" ", left_pad) .. text, left_pad
end

---@param text string
---@param width integer
---@return string
function M.pad_right(text, width)
	local w = M.text_width(text)
	if w >= width then
		return text
	end
	return text .. string.rep(" ", width - w)
end

---@param text string
---@param width integer
---@param align string|nil "left"|"center"|"right"
---@return string
function M.pad_aligned(text, width, align)
	local w = M.text_width(text)
	if w >= width then
		return text
	end

	local pad = width - w
	if align == "center" then
		local left = math.floor(pad / 2)
		local right = pad - left
		return string.rep(" ", left) .. text .. string.rep(" ", right)
	end

	if align == "right" then
		return string.rep(" ", pad) .. text
	end

	return M.pad_right(text, width)
end

return M
