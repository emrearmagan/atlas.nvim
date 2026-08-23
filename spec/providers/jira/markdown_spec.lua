local markdown = require("atlas.issues.providers.jira.converted.markdown")

local function doc(content)
	return { type = "doc", version = 1, content = content }
end

local function paragraph(content)
	return { type = "paragraph", content = content }
end

local function text(value, marks)
	return { type = "text", text = value, marks = marks }
end

local function converts(source, content)
	assert.are.same(doc(content), markdown.to_adf(source))
end

describe("Jira Markdown to ADF", function()
	it("converts paragraphs", function()
		converts("first\n\nsecond", {
			paragraph({ text("first") }),
			paragraph({ text("second") }),
		})
	end)

	it("converts inline marks", function()
		for _, case in ipairs({
			{ source = "**bold**", value = "bold", mark = { type = "strong" } },
			{ source = "*italic*", value = "italic", mark = { type = "em" } },
			{ source = "`code`", value = "code", mark = { type = "code" } },
			{ source = "~~gone~~", value = "gone", mark = { type = "strike" } },
			{
				source = "[click](https://example.com)",
				value = "click",
				mark = { type = "link", attrs = { href = "https://example.com" } },
			},
		}) do
			converts(case.source, { paragraph({ text(case.value, { case.mark }) }) })
		end
	end)

	it("converts mention links", function()
		local expected = {
			paragraph({ { type = "mention", attrs = { id = "abc", text = "@user", accessLevel = "" } } }),
		}
		for _, source in ipairs({ "[@user](atlas-mention:abc)", "[@user]{mention:abc}" }) do
			converts(source, expected)
		end
	end)

	it("converts emoji inside text and from shortcodes", function()
		converts("Done  now", {
			paragraph({
				text("Done "),
				{ type = "emoji", attrs = { shortName = ":check_mark:", text = ":check_mark:" } },
				text(" now"),
			}),
		})
		converts(":party_parrot:", {
			paragraph({ { type = "emoji", attrs = { shortName = ":party_parrot:", text = ":party_parrot:" } } }),
		})
	end)

	it("converts dates", function()
		converts("[2021-01-01](atlas-date:1609459200000)", {
			paragraph({ { type = "date", attrs = { timestamp = "1609459200000" } } }),
		})
	end)

	it("converts headings", function()
		for _, case in ipairs({
			{ source = "# Title", level = 1, value = "Title" },
			{ source = "### Sub", level = 3, value = "Sub" },
		}) do
			converts(case.source, {
				{ type = "heading", attrs = { level = case.level }, content = { text(case.value) } },
			})
		end
	end)

	it("converts code blocks", function()
		converts("```lua\nprint('hi')\n```", {
			{
				type = "codeBlock",
				attrs = { language = "lua" },
				content = { text("print('hi')") },
			},
		})
		converts("```\ncode\n```", {
			{ type = "codeBlock", content = { text("code") } },
		})
	end)

	it("converts panels", function()
		for _, case in ipairs({
			{ markdown = "NOTE", panel = "info", value = "info text" },
			{ markdown = "WARNING", panel = "warning", value = "warn" },
			{ markdown = "CAUTION", panel = "error", value = "danger" },
			{ markdown = "TIP", panel = "success", value = "nice" },
		}) do
			converts("> [!" .. case.markdown .. "]\n> " .. case.value, {
				{
					type = "panel",
					attrs = { panelType = case.panel },
					content = { paragraph({ text(case.value) }) },
				},
			})
		end
	end)

	it("converts blockquotes", function()
		converts("> quoted", {
			{ type = "blockquote", content = { paragraph({ text("quoted") }) } },
		})
	end)

	it("converts lists", function()
		converts("* a\n* b", {
			{
				type = "bulletList",
				content = {
					{ type = "listItem", content = { paragraph({ text("a") }) } },
					{ type = "listItem", content = { paragraph({ text("b") }) } },
				},
			},
		})
		converts("1. first\n2. second", {
			{
				type = "orderedList",
				content = {
					{ type = "listItem", content = { paragraph({ text("first") }) } },
					{ type = "listItem", content = { paragraph({ text("second") }) } },
				},
			},
		})
	end)

	it("converts horizontal rules", function()
		converts("above\n\n---\n\nbelow", {
			paragraph({ text("above") }),
			{ type = "rule" },
			paragraph({ text("below") }),
		})
	end)

	it("converts tables", function()
		converts("| A | B |\n| --- | --- |\n| 1 | 2 |", {
			{
				type = "table",
				content = {
					{
						type = "tableRow",
						content = {
							{ type = "tableHeader", content = { paragraph({ text("A") }) } },
							{ type = "tableHeader", content = { paragraph({ text("B") }) } },
						},
					},
					{
						type = "tableRow",
						content = {
							{ type = "tableCell", content = { paragraph({ text("1") }) } },
							{ type = "tableCell", content = { paragraph({ text("2") }) } },
						},
					},
				},
			},
		})
	end)

	it("handles empty input", function()
		converts("", {})
	end)
end)
