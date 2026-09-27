local markdown = require("atlas.formats.markdown")
local code_preview = require("atlas.ui.components.code_preview")
local shared_icons = require("atlas.ui.shared.icons")

local function span(line, start_col, end_col, hl_group)
	return { line = line, start_col = start_col, end_col = end_col, hl_group = hl_group }
end

local function target(kind, url, line, start_col, end_col)
	return { type = kind, url = url, line = line, start_col = start_col, end_col = end_col }
end

local function has_span(result, expected)
	for _, highlight in ipairs(result.highlights) do
		if
			highlight.line == expected.line
			and highlight.start_col == expected.start_col
			and highlight.end_col == expected.end_col
			and highlight.hl_group == expected.hl_group
		then
			return
		end
	end
	assert.are.same(expected, result.highlights)
end

local function has_group(result, group, line)
	for _, highlight in ipairs(result.highlights) do
		if highlight.hl_group == group and (line == nil or highlight.line == line) then
			return
		end
	end
	assert.are.same(group, result.highlights)
end

describe("Markdown parsing", function()
	local original_code_render, original_devicons, original_filetype_match

	before_each(function()
		original_code_render = code_preview.render
		original_devicons = package.loaded["nvim-web-devicons"]
		original_filetype_match = vim.filetype.match
	end)

	after_each(function()
		code_preview.render = original_code_render
		package.loaded["nvim-web-devicons"] = original_devicons
		vim.filetype.match = original_filetype_match
	end)

	it("preserves plain text, blank lines and trailing newlines", function()
		assert.are.same({ lines = { "" }, highlights = {}, targets = {} }, markdown.parse(""))
		assert.are.same({
			lines = { "", "first", "", "  second", "" },
			targets = {},
			highlights = {},
		}, markdown.parse("\r\nfirst\r\r\n  second\n"))
	end)

	it("tracks source blocks when rendering adds lines", function()
		local result = markdown.parse("# Title\n\n| A | B |\n| --- | --- |\n| x | y |\n\n```\ncode\n```", {
			width = 30,
			source_map = true,
		})
		assert.are.same({
			{ source_start = 0, source_end = 1, display_start = 0, display_end = 1 },
			{ source_start = 1, source_end = 2, display_start = 1, display_end = 2 },
			{ source_start = 2, source_end = 5, display_start = 2, display_end = 7 },
			{ source_start = 5, source_end = 6, display_start = 7, display_end = 8 },
			{ source_start = 6, source_end = 9, display_start = 8, display_end = 11 },
		}, result.source_map)
	end)

	it("renders single-level inline marks with byte offsets", function()
		for _, case in ipairs({
			{ "**bold**", "bold", "AtlasMarkdownStrong" },
			{ "__bold__", "bold", "AtlasMarkdownStrong" },
			{ "*italic*", "italic", "AtlasMarkdownEmphasis" },
			{ "_italic_", "italic", "AtlasMarkdownEmphasis" },
			{ "~~gone~~", "gone", "AtlasMarkdownStrike" },
			{ "`code`", "code", "AtlasMarkdownInlineCode" },
			{ "[click](https://example.com/a_(b))", "click", "AtlasMarkdownLink", "https://example.com/a_(b)" },
		}) do
			assert.are.same({
				lines = { "é " .. case[2] .. "!" },
				targets = case[4] and { target("link", case[4], 0, #"é ", #"é " + #case[2]) } or {},
				highlights = { span(0, #"é ", #"é " + #case[2], case[3]) },
			}, markdown.parse("é " .. case[1] .. "!"))
		end
		assert.are.same({
			lines = { "你好 🌍!" },
			targets = {},
			highlights = { span(0, #"你好 ", #"你好 🌍", "AtlasMarkdownStrong") },
		}, markdown.parse("你好 **🌍**!"))
	end)

	it("accounts for removed markers across multiple spans", function()
		assert.are.same({
			lines = { "bold and code" },
			targets = {},
			highlights = { span(0, 0, 4, "AtlasMarkdownStrong"), span(0, 9, 13, "AtlasMarkdownInlineCode") },
		}, markdown.parse("**bold** and `code`"))
	end)

	it("keeps identifiers, malformed marks and unsupported syntax readable", function()
		for _, source in ipairs({
			"snake_case_name and __init__value",
			"**unclosed and `unfinished",
			"2 * 3 * 4",
			"***nested***",
			"[missing](closing",
			"| Name | Value |",
			"####### not a heading",
		}) do
			assert.are.same({ lines = { source }, highlights = {}, targets = {} }, markdown.parse(source))
		end
	end)

	it("keeps unmatched emphasis and parses later marks", function()
		local unmatched = "**first **second "
		local result = markdown.parse(unmatched .. "__bold__")
		assert.same({ unmatched .. "bold" }, result.lines)
		assert.same({ span(0, #unmatched, #unmatched + 4, "AtlasMarkdownStrong") }, result.highlights)
		assert.same({ "closed" }, markdown.parse("**closed**").lines)
	end)

	it("handles escaped punctuation without interpreting it as formatting", function()
		assert.are.same({
			lines = { "*literal* C:\\path" },
			targets = {},
			highlights = {},
		}, markdown.parse("\\*literal\\* C:\\path"))
	end)

	it("keeps inline code literal and handles backtick delimiters", function()
		for _, case in ipairs({
			{ "`**raw** \\* [link](url)`", "**raw** \\* [link](url)" },
			{ "``a `tick` b``", "a `tick` b" },
			{ "`path\\`", "path\\" },
			{ "```inline```", "inline" },
			{ "` café `", "café" },
			{ "`  spaced  `", " spaced " },
		}) do
			assert.same({
				lines = { case[2] },
				targets = {},
				highlights = { span(0, 0, #case[2], "AtlasMarkdownInlineCode") },
			}, markdown.parse(case[1]))
		end
	end)

	it("mutes adjacent inline comments literally and preserves surrounding byte offsets", function()
		local prefix = "café "
		local first = "<!-- **raw** -->"
		local second = "<!--two-->"
		local suffix_start = #prefix + #first + #second + 1
		assert.are.same({
			lines = { prefix .. first .. second .. " live" },
			targets = {},
			highlights = {
				span(0, #prefix, #prefix + #first, "AtlasMarkdownComment"),
				span(0, #prefix + #first, suffix_start - 1, "AtlasMarkdownComment"),
				span(0, suffix_start, suffix_start + 4, "AtlasMarkdownStrong"),
			},
		}, markdown.parse(prefix .. first .. second .. " **live**"))
	end)

	it("preserves multiline comments through their close or EOF and resumes Markdown afterward", function()
		assert.are.same({
			lines = { "  <!--", "# raw", "", "```lua", "- item", "--> live", "After" },
			targets = {},
			highlights = {
				span(0, 0, #"  <!--", "AtlasMarkdownComment"),
				span(1, 0, #"# raw", "AtlasMarkdownComment"),
				span(3, 0, #"```lua", "AtlasMarkdownComment"),
				span(4, 0, #"- item", "AtlasMarkdownComment"),
				span(5, 0, 3, "AtlasMarkdownComment"),
				span(5, 4, 8, "AtlasMarkdownStrong"),
				span(6, 0, 5, "AtlasMarkdownHeading2"),
			},
		}, markdown.parse("  <!--\n# raw\n\n```lua\n- item\n--> **live**\n## After"))
		assert.are.same({
			lines = { "<!-->", "**raw**", "" },
			targets = {},
			highlights = {
				span(0, 0, #"<!-->", "AtlasMarkdownComment"),
				span(1, 0, #"**raw**", "AtlasMarkdownComment"),
			},
		}, markdown.parse("<!-->\n**raw**\n"))
	end)

	it("renders headings, lists and quotes with correctly shifted highlights", function()
		assert.are.same({
			lines = { "Title", "", "• first", "  • next", "3) third", "▎ quote" },
			targets = {},
			highlights = {
				span(0, 0, 5, "AtlasMarkdownHeading2"),
				span(2, 0, #"• ", "AtlasMarkdownList"),
				span(2, #"• ", #"• first", "AtlasMarkdownStrong"),
				span(3, 0, #"  • ", "AtlasMarkdownList"),
				span(4, 0, 3, "AtlasMarkdownList"),
				span(5, 0, #"▎ quote", "AtlasMarkdownQuote"),
				span(5, 0, #"▎ ", "AtlasMarkdownQuoteBar"),
				span(5, #"▎ ", #"▎ quote", "AtlasMarkdownEmphasis"),
			},
		}, markdown.parse("## Title\n\n- **first**\n  + next\n3) third\n> *quote*"))
	end)

	it("renders fenced code literally and resumes Markdown after the fence", function()
		local result = markdown.parse("```lua\n# raw\n**raw**\n```\n\n### Title")
		assert.are.same({
			"      lua  ",
			"  # raw    ",
			"  **raw**  ",
			"           ",
			"",
			"Title",
		}, result.lines)
		for line = 0, 3 do
			has_span(result, span(line, 0, 11, "AtlasMarkdownCode"))
		end
		has_span(result, span(0, 6, 9, "AtlasMarkdownCodeLabel"))
		has_span(result, span(5, 0, 5, "AtlasMarkdownHeading3"))
		assert.are.same({
			lines = { "         ", "  ```    ", "  *raw*  ", "         " },
			targets = {},
			highlights = {
				span(0, 0, 9, "AtlasMarkdownCode"),
				span(1, 0, 9, "AtlasMarkdownCode"),
				span(2, 0, 9, "AtlasMarkdownCode"),
				span(3, 0, 9, "AtlasMarkdownCode"),
			},
		}, markdown.parse("~~~~\n```\n*raw*\n~~~~"))
	end)

	it("reuses code preview syntax with normalized tabs and offsets past preceding Markdown", function()
		local received
		code_preview.render = function(opts)
			received = opts
			return {
				lines = { '      local name = "é"  ', "  return name  " },
				highlights = {
					{ line = 0, line_hl_group = "PreviewBackground" },
					{ line = 1, line_hl_group = "PreviewBackground" },
					span(0, 6, 11, "@keyword.lua"),
					span(1, 2, 8, "@keyword.return.lua"),
				},
			}
		end
		local result = markdown.parse('Intro\n\n```lua title\n\tlocal name = "é"\nreturn name\n```\n\nDone')

		assert.same({
			lines = { '    local name = "é"', "return name" },
			language = "lua",
			show_line_numbers = false,
			padding = 2,
			background_hl_group = "AtlasMarkdownCode",
		}, received)
		assert.equal("lua", result.lines[3]:match("^%s*(.-)%s*$"))
		assert.equal('      local name = "é"  ', result.lines[4])
		assert.equal("Done", result.lines[8])
		has_span(result, span(3, 6, 11, "@keyword.lua"))
		has_span(result, span(4, 2, 8, "@keyword.return.lua"))
		local body_highlights = {}
		for _, highlight in ipairs(result.highlights) do
			if highlight.line == 3 then
				body_highlights[#body_highlights + 1] = highlight.hl_group
			end
		end
		assert.same({ "PreviewBackground", "@keyword.lua" }, body_highlights)
		for line = 2, 5 do
			has_span(result, span(line, 0, #result.lines[line + 1], "PreviewBackground"))
		end

		for _, case in ipairs({ { "json,title=demo", "json" }, { "c++ linenos", "c++" }, { "{r}", "" } }) do
			local block = markdown.parse("```" .. case[1] .. "\nsource\n```")
			assert.equal(case[2], received.language)
			assert.equal(case[2], block.lines[1]:match("^%s*(.-)%s*$"))
		end
	end)

	it("keeps the remainder of an unclosed fence as code", function()
		local result = markdown.parse("```\n**raw**\n")
		assert.are.same({ "           ", "  **raw**  ", "           ", "           " }, result.lines)
		for line = 0, 3 do
			has_span(result, span(line, 0, 11, "AtlasMarkdownCode"))
		end
	end)

	it("renders Markdown and HTML images with labels and destinations", function()
		local url = "https://github.com/user-attachments/assets/925926a0-a795-4fc1-b62c-b05ca6a4acd1"
		local label = "659439788-01d01980-3584-409b-84e2-a19468ec2185"
		for _, case in ipairs({
			{ "![photo](https://example.com/image.png)", "photo", "https://example.com/image.png" },
			{ "![](image.png)", "image", "image.png" },
			{ '<img width="1366" height="1118" alt="' .. label .. '" src="' .. url .. '" />', label, url },
			{ "<img src='image.png'>", "image", "image.png" },
		}) do
			assert.are.same({
				lines = { "é 󰋩 " .. case[2] .. "!" },
				targets = { target("image", case[3], 0, #"é ", #"é 󰋩 " + #case[2]) },
				highlights = { span(0, #"é ", #"é 󰋩 " + #case[2], "AtlasMarkdownImage") },
			}, markdown.parse("é " .. case[1] .. "!"))
		end
	end)

	it("returns link and image destinations with rendered Unicode byte ranges", function()
		local result = markdown.parse(table.concat({
			"é [指南](https://example.com/a_(b)?q=1#top) · ![圖](asset_(v2).png) · [next](../next#part) · ![](empty.png)",
			'[titled](https://example.com/title "Title") ![angle](<https://example.com/a_(b).png> "Caption")',
		}, "\n"))
		assert.are.same({ "é 指南 · 󰋩 圖 · next · 󰋩 image", "titled 󰋩 angle" }, result.lines)
		assert.are.same({
			target("link", "https://example.com/a_(b)?q=1#top", 0, #"é ", #"é 指南"),
			target("image", "asset_(v2).png", 0, #"é 指南 · ", #"é 指南 · 󰋩 圖"),
			target("link", "../next#part", 0, #"é 指南 · 󰋩 圖 · ", #"é 指南 · 󰋩 圖 · next"),
			target(
				"image",
				"empty.png",
				0,
				#"é 指南 · 󰋩 圖 · next · ",
				#"é 指南 · 󰋩 圖 · next · 󰋩 image"
			),
			target("link", "https://example.com/title", 1, 0, #"titled"),
			target("image", "https://example.com/a_(b).png", 1, #"titled ", #"titled 󰋩 angle"),
		}, result.targets)
	end)

	it("keeps targets after block prefixes and table cell alignment", function()
		local result = markdown.parse(table.concat({
			"## [Hé](heading)",
			"  - [item](list)",
			"> [quote](quote)",
			"> [!NOTE] [Title](title)",
			"> ![圖](callout.png)",
			"",
			"| [Name](header) | Picture |",
			"| :---: | ---: |",
			"| [é](center) | ![UI](table.png) |",
			"| [zz](stripe) | [B](right) |",
		}, "\n"))
		assert.are.same({
			"Hé",
			"  • item",
			"▎ quote",
			"▎ 󰋽  Title",
			"▎ 󰋩 圖",
			"",
			"|------|---------|",
			"| Name | Picture |",
			"|------|---------|",
			"|  é   |    󰋩 UI |",
			"|  zz  |       B |",
			"|------|---------|",
		}, result.lines)
		assert.are.same({
			target("link", "heading", 0, 0, #"Hé"),
			target("link", "list", 1, #"  • ", #"  • item"),
			target("link", "quote", 2, #"▎ ", #"▎ quote"),
			target("link", "title", 3, #"▎ 󰋽  ", #"▎ 󰋽  Title"),
			target("image", "callout.png", 4, #"▎ ", #"▎ 󰋩 圖"),
			target("link", "header", 7, #"| ", #"| Name"),
			target("link", "center", 9, #"|  ", #"|  é"),
			target("image", "table.png", 9, #"|  é   |    ", #"|  é   |    󰋩 UI"),
			target("link", "stripe", 10, #"|  ", #"|  zz"),
			target("link", "right", 10, #"|  zz  |       ", #"|  zz  |       B"),
		}, result.targets)
	end)

	it("does not return targets for links inside literal code or comments", function()
		for _, source in ipairs({
			"`[link](url) ![image](image.png) <img src='image.png'>`",
			"```\n[link](url) ![image](image.png) <img src='image.png'>\n```",
			"text <!-- [link](url) ![image](image.png) <img src='image.png'> --> after",
			"<!--\n[link](url) ![image](image.png) <img src='image.png'>\n-->",
		}) do
			assert.are.same({}, markdown.parse(source).targets)
		end
	end)

	it("renders heading levels with inline highlights and no width-dependent decoration", function()
		for level = 1, 6 do
			local result = markdown.parse(string.rep("#", level) .. " café **🌍** ###", { width = 3 })
			assert.same({ "café 🌍" }, result.lines)
			assert.same({
				span(0, 0, #"café 🌍", "AtlasMarkdownHeading" .. level),
				span(0, #"café ", #"café 🌍", "AtlasMarkdownStrong"),
			}, result.highlights)
		end
	end)

	it("renders ordered and unordered lists with indentation", function()
		for _, case in ipairs({ { "-", "•" }, { "+", "•" }, { "*", "•" }, { "1.", "1." }, { "3)", "3)" } }) do
			local prefix = "  " .. case[2] .. " "
			local result = markdown.parse("  " .. case[1] .. " **item**")
			assert.same({ prefix .. "item" }, result.lines)
			assert.same({
				span(0, 0, #prefix, "AtlasMarkdownList"),
				span(0, #prefix, #prefix + 4, "AtlasMarkdownStrong"),
			}, result.highlights)
		end
	end)

	it("renders task states while preserving indentation and Unicode byte spans", function()
		for _, case in ipairs({
			{ " ", shared_icons.general("checkbox_unchecked"), "AtlasMarkdownTaskTodo" },
			{ "x", shared_icons.general("checkbox_checked"), "AtlasMarkdownTaskDone" },
			{ "X", shared_icons.general("checkbox_checked"), "AtlasMarkdownTaskDone" },
		}) do
			local prefix = "  " .. case[2] .. " "
			assert.are.same({
				lines = { prefix .. "你好" },
				targets = {},
				highlights = {
					span(0, 0, #prefix, case[3]),
					span(0, #prefix, #prefix + #"你好", "AtlasMarkdownStrong"),
				},
			}, markdown.parse("  - [" .. case[1] .. "] **你好**"))
		end
	end)

	it("requires closing fences to be at least as long as their opening fence", function()
		local result = markdown.parse("````\n```\nraw\n`````\nafter")
		assert.are.same({ "       ", "  ```  ", "  raw  ", "       ", "after" }, result.lines)
		for line = 0, 3 do
			has_span(result, span(line, 0, 7, "AtlasMarkdownCode"))
		end
	end)

	it("pads code and blank code lines to the requested width", function()
		local result = markdown.parse("```lua\nx\n\n```", { width = 8 })
		assert.are.same({ "   lua  ", "  x     ", "        ", "        " }, result.lines)
		for line = 0, 3 do
			has_span(result, span(line, 0, 8, "AtlasMarkdownCode"))
		end
		has_span(result, span(0, 3, 6, "AtlasMarkdownCodeLabel"))

		local clipped = markdown.parse("```typescript title=example\nreturn 'complete source'\n```", { width = 8 })
		assert.are.same({ "  type  ", "  return 'complete source'  ", "        " }, clipped.lines)
		has_span(clipped, span(0, 2, 6, "AtlasMarkdownCodeLabel"))

		for _, width in ipairs({ 1, 4 }) do
			local narrow = markdown.parse("```lua\nx\n```", { width = width })
			assert.are.same({ string.rep(" ", width), "  x  ", string.rep(" ", width) }, narrow.lines)
		end
	end)

	it("adds colored language icons when available and keeps code labels readable in narrow panels", function()
		local unknown = markdown.parse("```unknown\nx\n```", { width = 14 })
		local unlabeled = markdown.parse("```\nx\n```", { width = 14 })
		local requested = {}
		local icons = {
			lua = { "", "DevIconLua" },
			bash = { "", "DevIconBash" },
			javascript = { "", "DevIconJavascript" },
		}
		package.loaded["nvim-web-devicons"] = {
			get_icon_by_filetype = function(filetype, opts)
				assert.same({ default = false }, opts)
				requested[#requested + 1] = filetype
				local icon = icons[filetype]
				if icon then
					return icon[1], icon[2]
				end
			end,
		}
		vim.filetype.match = function(opts)
			return opts.filename == "code.js" and "javascript" or nil
		end

		for _, language in ipairs({ "lua", "bash", "js" }) do
			local filetype = language == "js" and "javascript" or language
			local icon, group = icons[filetype][1], icons[filetype][2]
			local source = "```" .. language .. "\nx\n```"
			local result = markdown.parse(source, { width = 14 })
			local padding = string.rep(" ", 10 - #language)
			assert.equals(padding .. icon .. " " .. language .. "  ", result.lines[1])
			assert.equals(14, vim.fn.strdisplaywidth(result.lines[1]))
			has_span(result, span(0, #padding, #padding + #icon, group))
			has_span(result, span(0, #padding + #icon + 1, #padding + #icon + 1 + #language, "AtlasMarkdownCodeLabel"))
			assert.equals(filetype, requested[#requested])

			local natural = markdown.parse(source)
			assert.equals("  " .. icon .. " " .. language .. "  ", natural.lines[1])
			local narrow = markdown.parse(source, { width = #language + 5 })
			assert.equals("   " .. language .. "  ", narrow.lines[1])
			for _, highlight in ipairs(narrow.highlights) do
				assert.is_not.equals(group, highlight.hl_group)
			end
		end

		assert.same(unknown, markdown.parse("```unknown\nx\n```", { width = 14 }))
		local calls = #requested
		assert.same(unlabeled, markdown.parse("```\nx\n```", { width = 14 }))
		assert.equals(calls, #requested)
	end)

	it("renders an empty code block with a background", function()
		assert.are.same({
			lines = { "    ", "    ", "    " },
			targets = {},
			highlights = {
				span(0, 0, 4, "AtlasMarkdownCode"),
				span(1, 0, 4, "AtlasMarkdownCode"),
				span(2, 0, 4, "AtlasMarkdownCode"),
			},
		}, markdown.parse("```\n```"))
	end)

	it("expands code tabs while keeping long content literal for the UI to wrap", function()
		local result = markdown.parse("```\n\ta **b** c\n```", { width = 4 })
		assert.are.same({ "    ", "      a **b** c  ", "    " }, result.lines)
		assert.are.same({
			span(0, 0, 4, "AtlasMarkdownCode"),
			span(1, 0, 17, "AtlasMarkdownCode"),
			span(2, 0, 4, "AtlasMarkdownCode"),
		}, result.highlights)
	end)

	it("renders horizontal rule markers at the requested width", function()
		for _, marker in ipairs({ "---", "***", "___", "- - -", "* * *", "_ _ _" }) do
			local result = markdown.parse(marker, { width = 6 })
			assert.same({ "──────" }, result.lines)
			assert.same({ span(0, 0, #"──────", "AtlasMarkdownRule") }, result.highlights)
		end
	end)

	it("renders supported callouts with styled titles, bars and inline content", function()
		for _, case in ipairs({
			{ "NOTE", "AtlasMarkdownNote", "▎ 󰋽  Note" },
			{ "TIP", "AtlasMarkdownTip", "▎ 󰌶  Tip" },
			{ "IMPORTANT", "AtlasMarkdownImportant", "▎ 󰅾  Important" },
			{ "WARNING", "AtlasMarkdownWarning", "▎ 󰀪  Warning" },
			{ "CAUTION", "AtlasMarkdownCaution", "▎ 󰳦  Caution" },
		}) do
			local result = markdown.parse("> [!" .. case[1] .. "]\n> **body**\nfollowing")
			assert.are.same({ case[3], "▎ body", "following" }, result.lines)
			has_span(result, span(0, 0, #case[3], case[2]))
			has_span(result, span(1, 0, #"▎ ", case[2]))
			has_span(result, span(1, #"▎ ", #"▎ body", "AtlasMarkdownStrong"))
			assert.equals(3, #result.highlights)
		end
	end)

	it("renders custom callout titles", function()
		local result = markdown.parse("> [!NOTE] Read this\n> details")
		assert.are.same({ "▎ 󰋽  Read this", "▎ details" }, result.lines)
		has_span(result, span(0, 0, #"▎ 󰋽  Read this", "AtlasMarkdownNote"))
	end)

	it("keeps callout bars across empty quoted lines without coloring body text", function()
		assert.are.same({
			lines = { "▎ 󰋽  Note", "▎ first", "▎ ", "▎ last" },
			targets = {},
			highlights = {
				span(0, 0, #"▎ 󰋽  Note", "AtlasMarkdownNote"),
				span(1, 0, #"▎ ", "AtlasMarkdownNote"),
				span(2, 0, #"▎ ", "AtlasMarkdownNote"),
				span(3, 0, #"▎ ", "AtlasMarkdownNote"),
			},
		}, markdown.parse("> [!NOTE]\n> first\n>\n> last"))
	end)

	it("shifts Unicode body highlights by the quote bar's byte length", function()
		assert.are.same({
			lines = { "▎ 󰌶  Tip", "▎ café 🌍 and code", "", "▎ 你好" },
			targets = {},
			highlights = {
				span(0, 0, #"▎ 󰌶  Tip", "AtlasMarkdownTip"),
				span(1, 0, #"▎ ", "AtlasMarkdownTip"),
				span(1, #"▎ café ", #"▎ café 🌍", "AtlasMarkdownStrong"),
				span(1, #"▎ café 🌍 and ", #"▎ café 🌍 and code", "AtlasMarkdownInlineCode"),
				span(3, 0, #"▎ 你好", "AtlasMarkdownQuote"),
				span(3, 0, #"▎ ", "AtlasMarkdownQuoteBar"),
				span(3, #"▎ ", #"▎ 你好", "AtlasMarkdownEmphasis"),
			},
		}, markdown.parse("> [!TIP]\n> café **🌍** and `code`\n\n> *你好*"))
	end)

	it("keeps unknown callouts readable as ordinary quotes", function()
		assert.are.same({
			lines = { "▎ [!UNKNOWN] custom", "▎ text" },
			targets = {},
			highlights = {
				span(0, 0, #"▎ [!UNKNOWN] custom", "AtlasMarkdownQuote"),
				span(0, 0, #"▎ ", "AtlasMarkdownQuoteBar"),
				span(1, 0, #"▎ text", "AtlasMarkdownQuote"),
				span(1, 0, #"▎ ", "AtlasMarkdownQuoteBar"),
			},
		}, markdown.parse("> [!UNKNOWN] custom\n> text"))
	end)

	it("handles adjacent callouts independently", function()
		local result = markdown.parse("> [!NOTE]\n> first\n> [!WARNING]\n> second")
		assert.are.same({ "▎ 󰋽  Note", "▎ first", "▎ 󰀪  Warning", "▎ second" }, result.lines)
		has_span(result, span(0, 0, #"▎ 󰋽  Note", "AtlasMarkdownNote"))
		has_span(result, span(2, 0, #"▎ 󰀪  Warning", "AtlasMarkdownWarning"))
		has_span(result, span(3, 0, #"▎ ", "AtlasMarkdownWarning"))
	end)

	it("formats table columns, headers and borders", function()
		local result = markdown.parse("| Name | Value |\n| --- | --- |\n| A | longer |")
		assert.are.same({
			"|------|--------|",
			"| Name | Value  |",
			"|------|--------|",
			"| A    | longer |",
			"|------|--------|",
		}, result.lines)
		has_group(result, "AtlasMarkdownTableHeader", 1)
		has_group(result, "AtlasMarkdownTableBorder", 0)
		has_group(result, "AtlasMarkdownTableBorder", 2)
		has_group(result, "AtlasMarkdownTableBorder", 4)
		local shaded_text = {}
		for _, highlight in ipairs(result.highlights) do
			if highlight.hl_group == "AtlasMarkdownTableHeader" then
				local content = result.lines[highlight.line + 1]:sub(highlight.start_col + 1, highlight.end_col)
				assert.is_nil(content:find("|", 1, true))
				shaded_text[#shaded_text + 1] = content
			end
		end
		assert.equals(" Name  Value  ", table.concat(shaded_text))
	end)

	it("supports tables without outer pipes and minimum-width columns", function()
		local result = markdown.parse("A | B\n--- | ---\nx | y")
		assert.are.same({
			"|---|---|",
			"| A | B |",
			"|---|---|",
			"| x | y |",
			"|---|---|",
		}, result.lines)
	end)

	it("honors left, center and right table alignment", function()
		local result = markdown.parse("Left | Center | Right\n:--- | :---: | ---:\nx | y | z")
		assert.equals("| x    |   y    |     z |", result.lines[4])
	end)

	it("preserves inline table highlights after padding and removed markers", function()
		local result = markdown.parse("Name | Value\n--- | ---\na | b\n**é** | `code`")
		assert.equals("| é    | code  |", result.lines[5])
		has_span(result, span(4, #"| ", #"| é", "AtlasMarkdownStrong"))
		has_span(result, span(4, #"| é    | ", #"| é    | code", "AtlasMarkdownInlineCode"))
		for index, highlight in ipairs(result.highlights) do
			if
				highlight.line == 4
				and highlight.hl_group ~= "AtlasMarkdownTableRow"
				and highlight.hl_group ~= "AtlasMarkdownTableBorder"
			then
				assert.are.same(
					span(4, highlight.start_col, highlight.end_col, "AtlasMarkdownTableRow"),
					result.highlights[index - 1]
				)
			end
		end
	end)

	it("keeps escaped pipes and pipes inside code within their table cells", function()
		local result = markdown.parse("A | B\n--- | ---\na\\|b | `c|d`")
		assert.equals("| a|b | c|d |", result.lines[4])
		has_span(result, span(3, #"| a|b | ", #"| a|b | c|d", "AtlasMarkdownInlineCode"))
	end)

	it("wraps table headers and cells while preserving alignment and logical row stripes", function()
		local result = markdown.parse(
			"Long name | Value\n:---: | ---:\none two three | abc def\nleft here | right now",
			{ width = 17 }
		)
		assert.are.same({
			"|-------|-------|",
			"| Long  | Value |",
			"| name  |       |",
			"|-------|-------|",
			"|  one  |   abc |",
			"|  two  |   def |",
			"| three |       |",
			"| left  | right |",
			"| here  |   now |",
			"|-------|-------|",
		}, result.lines)
		for _, line in ipairs(result.lines) do
			assert.equals(17, #line)
		end
		local shaded_rows = {}
		for _, highlight in ipairs(result.highlights) do
			if highlight.hl_group == "AtlasMarkdownTableRow" then
				shaded_rows[highlight.line] = true
			end
		end
		assert.are.same({ [7] = true, [8] = true }, shaded_rows)
		has_group(result, "AtlasMarkdownTableHeader", 1)
		has_group(result, "AtlasMarkdownTableHeader", 2)
		has_group(result, "AtlasMarkdownTableBorder", 3)
	end)

	it("wraps long multibyte table words without splitting characters", function()
		local source = "A | B\n--- | ---\n**éàîôüçñß** | abcdef"
		local result = markdown.parse(source, { width = 11 })
		assert.are.same({
			"|----|----|",
			"| A  | B  |",
			"|----|----|",
			"| éà | ab |",
			"| îô | cd |",
			"| üç | ef |",
			"| ñß |    |",
			"|----|----|",
		}, result.lines)
		for _, line in ipairs(result.lines) do
			assert.equals(11, vim.fn.strdisplaywidth(line))
		end
		for row = 3, 6 do
			has_span(result, span(row, #"| ", #"| éà", "AtlasMarkdownStrong"))
		end
	end)

	it("keeps wrapped table styles and link targets aligned with following content", function()
		local result = markdown.parse("A | B\n--- | ---\n**abcdef** | [uvwxyz](https://example.com)\n[after](next)", {
			width = 13,
		})
		assert.are.same({
			"|-----|-----|",
			"| A   | B   |",
			"|-----|-----|",
			"| abc | uvw |",
			"| def | xyz |",
			"|-----|-----|",
			"after",
		}, result.lines)
		for row = 3, 4 do
			has_span(result, span(row, #"| ", #"| abc", "AtlasMarkdownStrong"))
			has_span(result, span(row, #"| abc | ", #"| abc | uvw", "AtlasMarkdownLink"))
		end
		assert.are.same({
			target("link", "https://example.com", 3, #"| abc | ", #"| abc | uvw"),
			target("link", "https://example.com", 4, #"| def | ", #"| def | xyz"),
			target("link", "next", 6, 0, #"after"),
		}, result.targets)
		has_span(result, span(6, 0, #"after", "AtlasMarkdownLink"))
	end)

	it("drops table padding in narrow widths and preserves text when even minimum columns overflow", function()
		local source = "AB | C\n--- | ---\nxy | z"
		local result = markdown.parse(source, { width = 5 })
		assert.are.same({ "|-|-|", "|A|C|", "|B| |", "|-|-|", "|x|z|", "|y| |", "|-|-|" }, result.lines)
		for width = 1, 4 do
			assert.are.same(result, markdown.parse(source, { width = width }))
		end
	end)

	it("preserves extra body columns and fills missing cells", function()
		local result = markdown.parse("| A | B |\n| - | - |\n| a | b | extra |\n| c |")
		assert.are.same({
			"|---|---|-------|",
			"| A | B |       |",
			"|---|---|-------|",
			"| a | b | extra |",
			"| c |   |       |",
			"|---|---|-------|",
		}, result.lines)
		local shaded_text = {}
		for _, highlight in ipairs(result.highlights) do
			if highlight.hl_group == "AtlasMarkdownTableRow" then
				local content = result.lines[highlight.line + 1]:sub(highlight.start_col + 1, highlight.end_col)
				assert.is_nil(content:find("|", 1, true))
				shaded_text[#shaded_text + 1] = content
			end
		end
		assert.equals(" c           ", table.concat(shaded_text))
	end)

	it("leaves malformed table delimiters as ordinary lines", function()
		local source = "Name | Value\n-- | nope\na | b"
		assert.are.same(
			{ lines = { "Name | Value", "-- | nope", "a | b" }, highlights = {}, targets = {} },
			markdown.parse(source)
		)
	end)

	it("leaves text and highlight positions unchanged by the display width", function()
		for _, source in ipairs({
			"one two three",
			"abcdefgh",
			"**你好🌍abc**",
			"### one **two three**",
			"  1. **one two three**",
			"> **one two three**",
			"> [!NOTE]\n> one two three",
		}) do
			assert.are.same(markdown.parse(source), markdown.parse(source, { width = 3 }))
		end
	end)

	it("aligns multibyte table text while keeping highlight offsets in bytes", function()
		local result = markdown.parse("Name | Value\n--- | ---\n**café** | x")
		assert.are.same({
			"|------|-------|",
			"| Name | Value |",
			"|------|-------|",
			"| café | x     |",
			"|------|-------|",
		}, result.lines)
		has_span(result, span(3, #"| ", #"| café", "AtlasMarkdownStrong"))
	end)

	it("pads multibyte code without truncating it", function()
		local result = markdown.parse("```\né\n```", { width = 8 })
		assert.are.same({ "        ", "  é     ", "        " }, result.lines)
		has_span(result, span(1, 0, #"  é     ", "AtlasMarkdownCode"))
	end)

	it("applies custom highlights to block, inline and shared code styles", function()
		local options = { hl = { heading_1 = "CustomHeading", strong = "CustomStrong", code = "CustomCode" } }
		local result = markdown.parse("# **Title**\n```\ncode\n```", options)
		has_span(result, span(0, 0, 5, "CustomHeading"))
		has_span(result, span(0, 0, 5, "CustomStrong"))
		for line = 1, 3 do
			has_span(result, span(line, 0, #result.lines[line + 1], "CustomCode"))
		end
		assert.same({ "Title" }, markdown.parse("# **Title**").lines)
	end)
end)
