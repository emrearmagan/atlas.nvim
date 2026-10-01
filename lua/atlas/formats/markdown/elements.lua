local code_preview = require("atlas.ui.components.code_preview")
local highlight_groups = require("atlas.formats.markdown.highlights").groups
local html = require("atlas.formats.markdown.html")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = { inline = {}, block = {} }

local emphasis_styles = {
	["**"] = "strong",
	["__"] = "strong",
	["*"] = "em",
	["_"] = "em",
	["~~"] = "strike",
}

-- \*
-- { text = "*" }, consuming two source bytes.
function M.inline.escape(text)
	local punctuation = text:match("^\\(%p)")

	if punctuation then
		return { text = punctuation }, 2
	end
end

-- [docs](<url> "title")
-- { text = "docs", style = "link", url = "url" }
local function parse_link(text, is_image)
	local pattern = is_image and "^!(%b[])(%b())()" or "^(%b[])(%b())()"
	local label, destination, next_position = text:match(pattern)
	if not label then
		return
	end

	label = label:sub(2, -2)
	local url = destination:sub(2, -2)
	url = url:match("^%s*<([^>]*)>") or url:match("^%s*(%S*)")
	local consumed_bytes = next_position - 1
	local style = "link"

	if is_image then
		if label == "" then
			label = "image"
		end

		label = "󰋩 " .. label
		style = "image"
	elseif label:match("^!%b[]%b()$") then
		local image = parse_link(label, true)
		label = image.text
	end

	return { text = label, style = style, url = url }, consumed_bytes
end

-- [docs](https://example.com)
-- { text = "docs", style = "link", url = "https://example.com" }.
function M.inline.link(text)
	return parse_link(text, false)
end

-- ![logo](https://example.com/logo.png)
-- { text = "󰋩 logo", style = "image", url = "https://example.com/logo.png" }.
-- An empty label displays "image".
function M.inline.image(text)
	return parse_link(text, true)
end

-- `**bold**`
-- { text = "**bold**", style = "inline_code" }.
function M.inline.code(text)
	local delimiter = text:match("^(`+)")
	if not delimiter then
		return
	end

	local closing_position = text:find(delimiter, #delimiter + 1, true)
	if not closing_position then
		return { text = delimiter }, #delimiter
	end

	local content = text:sub(#delimiter + 1, closing_position - 1)
	local consumed_bytes = closing_position + #delimiter - 1
	if content:match("^ .* $") and content:find("[^ ]") then
		content = content:sub(2, -2)
	end

	return { text = content, style = "inline_code" }, consumed_bytes
end

-- **bold** / *word* / ~~removed~~
-- { text = "bold", style = "strong" }
-- { text = "word", style = "em" }
-- { text = "removed", style = "strike" }
-- Underscores also mark emphasis; underscores inside words stay literal.
function M.inline.emphasis(text, previous_character)
	local delimiter = text:match("^(%*+)") or text:match("^(_+)") or text:match("^(~+)")
	if not delimiter then
		return
	end

	local style = emphasis_styles[delimiter]
	if not style then
		return { text = delimiter }, #delimiter
	end

	if delimiter:sub(1, 1) == "_" and previous_character:match("%w") then
		return { text = delimiter }, #delimiter
	end

	if text:sub(#delimiter + 1, #delimiter + 1):match("%s") then
		return { text = delimiter }, #delimiter
	end

	local closing_position = text:find(delimiter, #delimiter + 1, true)
	if not closing_position then
		return { text = delimiter }, #delimiter
	end

	local content = text:sub(#delimiter + 1, closing_position - 1)
	local after = text:sub(closing_position + #delimiter, closing_position + #delimiter)
	if content:match("%s$") or (delimiter:sub(1, 1) == "_" and after:match("%w")) then
		return { text = delimiter }, #delimiter
	end

	local display_text = content:gsub("\\(%p)", "%1")
	local consumed_bytes = closing_position + #delimiter - 1

	return { text = display_text, style = style }, consumed_bytes
end

---@type (fun(text: string, previous_character: string): table?, integer?)[]
local inline_handlers = {
	M.inline.escape,
	M.inline.image,
	html.inline.image,
	M.inline.link,
	M.inline.code,
	html.inline.comment,
	M.inline.emphasis,
}

-- Hello **world**
-- { { text = "Hello " }, { text = "world", style = "strong" } }.
function M.parse_inline(text)
	local fragments = {}
	local position = 1

	while position <= #text do
		local remaining_text = text:sub(position)
		local previous_character = text:sub(position - 1, position - 1)
		local fragment, consumed_bytes

		for _, handler in ipairs(inline_handlers) do
			fragment, consumed_bytes = handler(remaining_text, previous_character)
			if fragment then
				break
			end
		end

		if not fragment then
			local plain_text = remaining_text:match("^[^\\%[!`*_~<]+")
			if not plain_text then
				plain_text = remaining_text:sub(1, 1)
			end

			fragment = { text = plain_text }
			consumed_bytes = #plain_text
		end

		fragments[#fragments + 1] = fragment
		position = position + consumed_bytes
	end

	return fragments
end

-- { { text = "Hello " }, { text = "world", style = "strong" } }.
-- "Hello world".
function M.join(fragments)
	local display_parts = {}

	for _, fragment in ipairs(fragments) do
		display_parts[#display_parts + 1] = fragment.text
	end

	return table.concat(display_parts)
end

-- Wrap display text, keeping each fragment's styling and link target.
function M.wrap(fragments, width)
	local content = M.join(fragments)
	if not width or vim.fn.strdisplaywidth(content) <= width then
		return { fragments }
	end

	local lines, offsets = utils.wrap_line(content, width)
	local rows = {}
	for index, line in ipairs(lines) do
		local row = {}
		local offset = 0
		local first, last = offsets[index], offsets[index] + #line
		for _, fragment in ipairs(fragments) do
			local finish = offset + #fragment.text
			if finish > first and offset < last then
				row[#row + 1] = vim.tbl_extend("force", fragment, {
					text = fragment.text:sub(math.max(1, first - offset + 1), last - offset),
				})
			end
			offset = finish
		end
		rows[#rows + 1] = row
	end
	return rows
end

--   ```lua
--   print(1)
--   ```
-- a right-aligned " lua" label, "  print(1)  ", and a blank footer.
function M.block.code(lines, index, opts)
	local fence, language = lines[index]:match("^(```+)([^`]*)$")
	if not fence then
		fence, language = lines[index]:match("^(~~~+)(.*)$")
	end

	if not fence then
		return
	end

	language = language:match("^%s*([%w_+#.-]+)") or ""
	local closing_pattern = "^(" .. fence:sub(1, 1) .. "+)%s*$"
	local body = {}
	index = index + 1

	while index <= #lines do
		local closing = lines[index]:match(closing_pattern)
		if closing and #closing >= #fence then
			index = index + 1
			break
		end

		body[#body + 1] = lines[index]:gsub("\t", "    ")
		index = index + 1
	end

	if #body == 0 then
		body[1] = ""
	end

	local code_language = opts.language_aliases and opts.language_aliases[language] or language

	local preview = code_preview.render({
		lines = body,
		language = code_language ~= "" and code_language or opts.language,
		file_path = opts.file_path,
		show_line_numbers = false,
		width = opts.width,
		padding = 2,
		background_hl_group = opts.hl and opts.hl.code or highlight_groups.code,
	})

	local icon, icon_hl
	if language ~= "" then
		local ok, devicons = pcall(require, "nvim-web-devicons")
		if ok then
			local filetype = vim.filetype.match({ filename = "code." .. language }) or language
			icon, icon_hl = devicons.get_icon_by_filetype(filetype, { default = false })
		end
	end

	local icon_width = icon and vim.fn.strdisplaywidth(icon) + 1 or 0
	local rows = {}
	local label_width = vim.fn.strdisplaywidth(language) + icon_width + 4
	local width = label_width

	for _, line in ipairs(preview.lines) do
		rows[#rows + 1] = { { text = line } }
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end

	for _, highlight in ipairs(preview.highlights) do
		local row = rows[highlight.line + 1]
		if highlight.line_hl_group then
			row.hl_group = highlight.line_hl_group
		else
			row.highlights = row.highlights or {}
			row.highlights[#row.highlights + 1] = highlight
		end
	end

	width = opts.width or width
	local header = { { text = "" } }
	-- Language tokens are ASCII, so clipping bytes also preserves characters.
	local label = language:sub(1, math.max(0, width - 4))

	if label ~= "" then
		local prefix = icon and width >= label_width and (icon .. " ") or ""
		local label_padding = width - vim.fn.strdisplaywidth(prefix .. label) - 2
		header = {
			{ text = string.rep(" ", label_padding) .. prefix },
			{ text = label, style = "code_lang" },
			{ text = "  " },
		}
		if prefix ~= "" then
			header.highlights = {
				{ start_col = label_padding, end_col = label_padding + #icon, hl_group = icon_hl },
			}
		end
	end

	local footer = { { text = "" } }
	header.hl_group = rows[1].hl_group
	footer.hl_group = header.hl_group
	table.insert(rows, 1, header)
	rows[#rows + 1] = footer

	for _, row in ipairs(rows) do
		row.pad = width
	end

	return rows, index
end

local callout_styles = {
	NOTE = { icon = "󰋽", hl = "panel_info" },
	TIP = { icon = "󰌶", hl = "panel_success" },
	IMPORTANT = { icon = "󰅾", hl = "panel_important" },
	WARNING = { icon = "󰀪", hl = "panel_warning" },
	CAUTION = { icon = "󰳦", hl = "panel_error" },
}

local function quote_rows(row, width, bar_style)
	local rows = M.wrap(row, width and math.max(1, width - 2))
	for _, wrapped in ipairs(rows) do
		wrapped.hl = row.hl
		table.insert(wrapped, 1, { text = "▎ ", style = bar_style })
	end
	return rows
end

--   > [!TIP] Try this
--   > Use **x**
--
--   ▎ 󰌶  Try this
--   ▎ Use x
function M.block.callout(lines, index, opts)
	local kind, title = lines[index]:match("^>%s?%[!(%a+)%]%s*(.*)$")
	kind = kind and kind:upper()
	local style = callout_styles[kind]
	if not style then
		return
	end

	if title == "" then
		title = kind:sub(1, 1) .. kind:sub(2):lower()
	end

	local heading = M.parse_inline(title)
	heading.hl = style.hl
	table.insert(heading, 1, { text = style.icon .. "  " })

	local rows = quote_rows(heading, opts.width)
	index = index + 1

	while index <= #lines do
		local content = lines[index]:match("^>%s?(.*)$")
		if not content or content:match("^%[!%a+%]") then
			break
		end

		vim.list_extend(rows, quote_rows(M.parse_inline(content), opts.width, style.hl))
		index = index + 1
	end

	return rows, index
end

-- ### Release **notes** ###
-- Release notes
function M.block.heading(lines, index)
	local marker, content = lines[index]:match("^(#+)%s+(.*)$")
	if not marker or #marker > 6 then
		return
	end

	local level = #marker
	content = content:gsub("%s+#+%s*$", "")

	local row = M.parse_inline(content)
	row.hl = "heading_" .. level

	return { row }, index + 1
end

-- --- / * * * / ___
-- ───
function M.block.rule(lines, index, opts)
	local marker = lines[index]:gsub("%s", "")
	if not (marker:match("^%-%-%-+$") or marker:match("^%*%*%*+$") or marker:match("^___+$")) then
		return
	end

	local row = { { text = string.rep("─", opts.width or 3), style = "rule" } }
	return { row }, index + 1
end

-- - **Fix** / - [x] Done / - [ ] Later / 1. First
-- • Fix / 󰄵 Done / 󰄱 Later / 1. First.
function M.block.list(lines, index)
	local indent, marker, content = lines[index]:match("^(%s*)([-+*])%s+(.*)$")
	if not marker then
		indent, marker, content = lines[index]:match("^(%s*)(%d+[.)])%s+(.*)$")
	end

	if not marker then
		return
	end

	local style = "list_marker"
	local checked, task = content:match("^%[([ xX])%]%s+(.*)$")

	if checked then
		content = task

		if checked == " " then
			marker = icons.general("checkbox_unchecked")
			style = "task_todo"
		else
			marker = icons.general("checkbox_checked")
			style = "task_done"
		end
	elseif marker:match("^[-+*]$") then
		marker = "•"
	end

	local row = M.parse_inline(content)
	table.insert(row, 1, { text = indent .. marker .. " ", style = style })

	return { row }, index + 1
end

-- > **Note**
-- ▎ Note
function M.block.quote(lines, index, opts)
	local content = lines[index]:match("^>%s?(.*)$")
	if not content then
		return
	end

	local row = M.parse_inline(content)
	row.hl = "quote"

	return quote_rows(row, opts.width, "quote_bar"), index + 1
end

-- Hello **world**
-- Hello world
function M.block.paragraph(lines, index)
	return { M.parse_inline(lines[index]) }, index + 1
end

return M
