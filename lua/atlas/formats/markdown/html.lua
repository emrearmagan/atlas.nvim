local M = { inline = {}, block = {} }

-- <img src="https://example.com/logo.png" alt="logo" />
-- { text = "󰋩 logo", style = "image", url = "https://example.com/logo.png" }.
-- An empty label displays "image".
function M.inline.image(text)
	local tag = text:match("^<img%s[^>]*>")
	if not tag then
		return
	end

	local attributes = {}
	for name, _, value in tag:gmatch("([%w_-]+)%s*=%s*(['\"])(.-)%2") do
		attributes[name] = value
	end
	if not attributes.src or attributes.src == "" then
		return
	end

	local label = attributes.alt
	if not label or label == "" then
		label = "image"
	end
	return { text = "󰋩 " .. label, style = "image", url = attributes.src }, #tag
end

-- <!-- **draft** -->
-- { text = "<!-- **draft** -->", style = "comment" }.
-- Inline comments must close on the same line.
function M.inline.comment(text)
	if text:sub(1, 4) ~= "<!--" then
		return
	end

	local _, closing_end = text:find("-->", 5, true)
	if closing_end then
		return { text = text:sub(1, closing_end), style = "comment" }, closing_end
	end
end

--   <!--
--   **draft**
--   -->
-- the same lines, muted, with Markdown markers kept literal.
function M.block.comment(lines, index)
	local opening_end = lines[index]:match("^%s*<!%-%-()")
	if not opening_end then
		return
	end

	local rows = {}

	while index <= #lines do
		local line = lines[index]
		rows[#rows + 1] = { { text = line, style = "comment" } }

		if line:find("-->", opening_end, true) then
			return rows, index + 1
		end

		index = index + 1
		opening_end = 1
	end

	return rows, index
end

-- <a id="github"></a>
-- {}.
function M.block.anchor(lines, index)
	if lines[index]:match("^%s*<a%s[^>]*>%s*</a>%s*$") then
		return {}, index + 1
	end
end

-- <p> / <p align="center"> / </p>
-- {}.
function M.block.paragraph(lines, index)
	local line = lines[index]
	if line:match("^%s*</?p>%s*$") or line:match("^%s*<p%s[^>]*>%s*$") then
		return {}, index + 1
	end
end

-- <details> / </details>
-- {}.
function M.block.details(lines, index)
	if lines[index]:match("^%s*</?details>%s*$") then
		return {}, index + 1
	end
end

-- <summary><strong>Title</strong></summary>
-- { { { text = "▾ Title" } } }.
function M.block.summary(lines, index)
	local title = lines[index]:match("^%s*<summary>(.-)</summary>%s*$")
	if title then
		return { { { text = "▾ " .. title:gsub("<[^>]*>", "") } } }, index + 1
	end
end

return M
