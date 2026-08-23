local adf = require("atlas.issues.providers.jira.converted.adf")

local function doc(content)
	return { type = "doc", version = 1, content = content }
end

local function paragraph(content)
	return { type = "paragraph", content = content }
end

local function text(value, marks)
	return { type = "text", text = value, marks = marks }
end

local function converts(content, expected)
	assert.equals(expected, adf.to_markdown(doc(content)))
end

local function list_item(value)
	return { type = "listItem", content = { paragraph({ text(value) }) } }
end

describe("Jira ADF to Markdown", function()
	it("converts text and marks", function()
		for _, case in ipairs({
			{ value = "hello world", expected = "hello world" },
			{ value = "bold", mark = { type = "strong" }, expected = "**bold**" },
			{ value = "italic", mark = { type = "em" }, expected = "*italic*" },
			{ value = "code", mark = { type = "code" }, expected = "`code`" },
			{ value = "gone", mark = { type = "strike" }, expected = "~~gone~~" },
			{
				value = "click",
				mark = { type = "link", attrs = { href = "https://example.com" } },
				expected = "[click](https://example.com)",
			},
		}) do
			local marks = case.mark and { case.mark } or nil
			converts({ paragraph({ text(case.value, marks) }) }, case.expected)
		end
	end)

	it("converts hard breaks", function()
		converts({
			paragraph({ text("a"), { type = "hardBreak" }, text("b") }),
		}, "a  \nb")
	end)

	it("converts headings", function()
		for _, case in ipairs({
			{ level = 1, value = "Title", expected = "# Title" },
			{ level = 3, value = "Sub", expected = "### Sub" },
		}) do
			converts({
				{ type = "heading", attrs = { level = case.level }, content = { text(case.value) } },
			}, case.expected)
		end
	end)

	it("converts code blocks", function()
		converts({
			{
				type = "codeBlock",
				attrs = { language = "lua" },
				content = { text("print('hi')") },
			},
		}, "```lua\nprint('hi')\n```")
		converts({
			{ type = "codeBlock", content = { text("code") } },
		}, "```\ncode\n```")
	end)

	it("converts lists", function()
		converts({
			{ type = "bulletList", content = { list_item("a"), list_item("b") } },
		}, "* a\n* b")
		converts({
			{ type = "orderedList", content = { list_item("first"), list_item("second") } },
		}, "1. first\n2. second")
		converts({
			{
				type = "taskList",
				content = {
					{
						type = "taskItem",
						attrs = { state = "TODO" },
						content = { paragraph({ text("todo") }) },
					},
					{
						type = "taskItem",
						attrs = { state = "DONE" },
						content = { paragraph({ text("done") }) },
					},
				},
			},
		}, "- [ ] todo\n- [x] done")
	end)

	it("converts blockquotes", function()
		converts({
			{ type = "blockquote", content = { paragraph({ text("quoted") }) } },
		}, "> quoted")
	end)

	it("converts panels", function()
		for _, case in ipairs({
			{ panel = "info", value = "info text", expected = "> [!NOTE]\n> info text" },
			{ panel = "warning", value = "warn", expected = "> [!WARNING]\n> warn" },
		}) do
			converts({
				{
					type = "panel",
					attrs = { panelType = case.panel },
					content = { paragraph({ text(case.value) }) },
				},
			}, case.expected)
		end
	end)

	it("converts horizontal rules", function()
		converts({
			paragraph({ text("above") }),
			{ type = "rule" },
			paragraph({ text("below") }),
		}, "above\n\n---\n\nbelow")
	end)

	it("converts mentions", function()
		converts({
			paragraph({ { type = "mention", attrs = { id = "abc", text = "@user" } } }),
		}, "[@user](atlas-mention:abc)")
		converts({
			paragraph({ { type = "mention", attrs = { text = "@user" } } }),
		}, "@user")
	end)

	it("converts known and unknown emoji", function()
		converts({
			paragraph({ { type = "emoji", attrs = { shortName = ":smile:" } } }),
		}, "")
		converts({
			paragraph({
				{
					type = "emoji",
					attrs = {
						id = "atlassian-check_mark",
						shortName = ":check_mark:",
						text = ":x:",
					},
				},
			}),
		}, "")
		converts({
			paragraph({ { type = "emoji", attrs = { shortName = ":party_parrot:" } } }),
		}, ":party_parrot:")
	end)

	it("converts statuses", function()
		converts({
			paragraph({ { type = "status", attrs = { text = "Done", color = "green" } } }),
		}, " Done")
	end)

	it("converts dates", function()
		converts({
			paragraph({ { type = "date", attrs = { timestamp = "1609459200000" } } }),
		}, "[2021-01-01](atlas-date:1609459200000)")
	end)

	it("converts cards", function()
		converts({
			paragraph({
				{ type = "inlineCard", attrs = { url = "https://jira.example.com/browse/PROJ-1" } },
			}),
		}, "[PROJ-1](https://jira.example.com/browse/PROJ-1)")
		converts({
			{ type = "blockCard", attrs = { url = "https://example.com" } },
		}, "[https://example.com](https://example.com)")
	end)

	it("converts media", function()
		converts({
			{ type = "mediaSingle", content = { { type = "media", attrs = { url = "https://img.png" } } } },
		}, "![](https://img.png)")
	end)

	it("converts tables", function()
		converts({
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
		}, "| A | B |\n| --- | --- |\n| 1 | 2 |")
	end)

	it("ignores unknown nodes", function()
		converts({ { type = "unknownWidget", attrs = {} } }, "")
	end)

	it("handles nil and node arrays", function()
		assert.equals("", adf.to_markdown(nil))
		assert.equals(
			"a\n\nb",
			adf.to_markdown({
				paragraph({ text("a") }),
				paragraph({ text("b") }),
			})
		)
	end)
end)
