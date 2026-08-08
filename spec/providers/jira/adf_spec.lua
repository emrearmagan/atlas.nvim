local adf = require("atlas.issues.providers.jira.converted.adf")

describe("adf to markdown", function()
	describe("text", function()
		it("converts plain text", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{ type = "paragraph", content = { { type = "text", text = "hello world" } } },
				},
			}
			assert.equals("hello world", adf.to_markdown(doc))
		end)

		it("converts bold text", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = {
							{ type = "text", text = "bold", marks = { { type = "strong" } } },
						},
					},
				},
			}
			assert.equals("**bold**", adf.to_markdown(doc))
		end)

		it("converts italic text", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = {
							{ type = "text", text = "italic", marks = { { type = "em" } } },
						},
					},
				},
			}
			assert.equals("*italic*", adf.to_markdown(doc))
		end)

		it("converts inline code", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = {
							{ type = "text", text = "code", marks = { { type = "code" } } },
						},
					},
				},
			}
			assert.equals("`code`", adf.to_markdown(doc))
		end)

		it("converts strikethrough", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = {
							{ type = "text", text = "gone", marks = { { type = "strike" } } },
						},
					},
				},
			}
			assert.equals("~~gone~~", adf.to_markdown(doc))
		end)

		it("converts link mark", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = {
							{
								type = "text",
								text = "click",
								marks = { { type = "link", attrs = { href = "https://example.com" } } },
							},
						},
					},
				},
			}
			assert.equals("[click](https://example.com)", adf.to_markdown(doc))
		end)
	end)

	describe("hardBreak", function()
		it("inserts line break", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = {
							{ type = "text", text = "a" },
							{ type = "hardBreak" },
							{ type = "text", text = "b" },
						},
					},
				},
			}
			assert.equals("a  \nb", adf.to_markdown(doc))
		end)
	end)

	describe("heading", function()
		it("converts h1", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{ type = "heading", attrs = { level = 1 }, content = { { type = "text", text = "Title" } } },
				},
			}
			assert.equals("# Title", adf.to_markdown(doc))
		end)

		it("converts h3", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{ type = "heading", attrs = { level = 3 }, content = { { type = "text", text = "Sub" } } },
				},
			}
			assert.equals("### Sub", adf.to_markdown(doc))
		end)
	end)

	describe("codeBlock", function()
		it("converts with language", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "codeBlock",
						attrs = { language = "lua" },
						content = { { type = "text", text = "print('hi')" } },
					},
				},
			}
			assert.equals("```lua\nprint('hi')\n```", adf.to_markdown(doc))
		end)

		it("converts without language", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{ type = "codeBlock", content = { { type = "text", text = "code" } } },
				},
			}
			assert.equals("```\ncode\n```", adf.to_markdown(doc))
		end)
	end)

	describe("bulletList", function()
		it("converts items", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "bulletList",
						content = {
							{
								type = "listItem",
								content = { { type = "paragraph", content = { { type = "text", text = "a" } } } },
							},
							{
								type = "listItem",
								content = { { type = "paragraph", content = { { type = "text", text = "b" } } } },
							},
						},
					},
				},
			}
			assert.equals("* a\n* b", adf.to_markdown(doc))
		end)
	end)

	describe("orderedList", function()
		it("converts numbered items", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "orderedList",
						content = {
							{
								type = "listItem",
								content = { { type = "paragraph", content = { { type = "text", text = "first" } } } },
							},
							{
								type = "listItem",
								content = { { type = "paragraph", content = { { type = "text", text = "second" } } } },
							},
						},
					},
				},
			}
			assert.equals("1. first\n2. second", adf.to_markdown(doc))
		end)
	end)

	describe("taskList", function()
		it("converts todo and done items", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "taskList",
						content = {
							{
								type = "taskItem",
								attrs = { state = "TODO" },
								content = { { type = "paragraph", content = { { type = "text", text = "todo" } } } },
							},
							{
								type = "taskItem",
								attrs = { state = "DONE" },
								content = { { type = "paragraph", content = { { type = "text", text = "done" } } } },
							},
						},
					},
				},
			}
			assert.equals("- [ ] todo\n- [x] done", adf.to_markdown(doc))
		end)
	end)

	describe("blockquote", function()
		it("prefixes lines with >", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "blockquote",
						content = { { type = "paragraph", content = { { type = "text", text = "quoted" } } } },
					},
				},
			}
			assert.equals("> quoted", adf.to_markdown(doc))
		end)
	end)

	describe("panel", function()
		it("renders info panel", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "panel",
						attrs = { panelType = "info" },
						content = { { type = "paragraph", content = { { type = "text", text = "info text" } } } },
					},
				},
			}
			assert.equals("> [!NOTE]\n> info text", adf.to_markdown(doc))
		end)

		it("renders warning panel", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "panel",
						attrs = { panelType = "warning" },
						content = { { type = "paragraph", content = { { type = "text", text = "warn" } } } },
					},
				},
			}
			assert.equals("> [!WARNING]\n> warn", adf.to_markdown(doc))
		end)
	end)

	describe("rule", function()
		it("converts to hr", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{ type = "paragraph", content = { { type = "text", text = "above" } } },
					{ type = "rule" },
					{ type = "paragraph", content = { { type = "text", text = "below" } } },
				},
			}
			assert.equals("above\n\n---\n\nbelow", adf.to_markdown(doc))
		end)
	end)

	describe("mention", function()
		it("converts with id", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = { { type = "mention", attrs = { id = "abc", text = "@user" } } },
					},
				},
			}
			assert.equals("[@user](atlas-mention:abc)", adf.to_markdown(doc))
		end)

		it("converts without id", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = { { type = "mention", attrs = { text = "@user" } } },
					},
				},
			}
			assert.equals("@user", adf.to_markdown(doc))
		end)
	end)

	describe("emoji", function()
		it("renders shortName", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = { { type = "emoji", attrs = { shortName = ":smile:" } } },
					},
				},
			}
			assert.equals("", adf.to_markdown(doc))
		end)

		it("uses shortName and ignores text attrs", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = {
							{
								type = "emoji",
								attrs = {
									id = "atlassian-check_mark",
									shortName = ":check_mark:",
									text = ":x:",
								},
							},
						},
					},
				},
			}

			assert.equals("", adf.to_markdown(doc))
		end)

		it("renders unknown shortName as reversible token", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = { { type = "emoji", attrs = { shortName = ":party_parrot:" } } },
					},
				},
			}
			assert.equals(":party_parrot:", adf.to_markdown(doc))
		end)
	end)

	describe("status", function()
		it("renders status with color icon", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = { { type = "status", attrs = { text = "Done", color = "green" } } },
					},
				},
			}
			local result = adf.to_markdown(doc)
			assert.is_truthy(result:find("Done"))
		end)
	end)

	describe("date", function()
		it("converts timestamp to link", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = { { type = "date", attrs = { timestamp = "1609459200000" } } },
					},
				},
			}
			local result = adf.to_markdown(doc)
			assert.is_truthy(result:find("atlas%-date:1609459200000"))
			assert.is_truthy(result:find("2021%-01%-01"))
		end)
	end)

	describe("cards", function()
		it("converts inlineCard", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "paragraph",
						content = {
							{ type = "inlineCard", attrs = { url = "https://jira.example.com/browse/PROJ-1" } },
						},
					},
				},
			}
			assert.equals("[PROJ-1](https://jira.example.com/browse/PROJ-1)", adf.to_markdown(doc))
		end)

		it("converts blockCard", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{ type = "blockCard", attrs = { url = "https://example.com" } },
				},
			}
			assert.equals("[https://example.com](https://example.com)", adf.to_markdown(doc))
		end)
	end)

	describe("media", function()
		it("converts media node", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{ type = "mediaSingle", content = { { type = "media", attrs = { url = "https://img.png" } } } },
				},
			}
			assert.equals("![](https://img.png)", adf.to_markdown(doc))
		end)
	end)

	describe("table", function()
		it("converts table with header and rows", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{
						type = "table",
						content = {
							{
								type = "tableRow",
								content = {
									{
										type = "tableHeader",
										content = {
											{ type = "paragraph", content = { { type = "text", text = "A" } } },
										},
									},
									{
										type = "tableHeader",
										content = {
											{ type = "paragraph", content = { { type = "text", text = "B" } } },
										},
									},
								},
							},
							{
								type = "tableRow",
								content = {
									{
										type = "tableCell",
										content = {
											{ type = "paragraph", content = { { type = "text", text = "1" } } },
										},
									},
									{
										type = "tableCell",
										content = {
											{ type = "paragraph", content = { { type = "text", text = "2" } } },
										},
									},
								},
							},
						},
					},
				},
			}
			local result = adf.to_markdown(doc)
			assert.equals("| A | B |\n| --- | --- |\n| 1 | 2 |", result)
		end)
	end)

	describe("unknown nodes", function()
		it("returns empty for unknown type", function()
			local doc = {
				type = "doc",
				version = 1,
				content = {
					{ type = "unknownWidget", attrs = {} },
				},
			}
			assert.equals("", adf.to_markdown(doc))
		end)
	end)

	describe("non-doc input", function()
		it("handles nil", function()
			assert.equals("", adf.to_markdown(nil))
		end)

		it("handles array of nodes", function()
			local nodes = {
				{ type = "paragraph", content = { { type = "text", text = "a" } } },
				{ type = "paragraph", content = { { type = "text", text = "b" } } },
			}
			assert.equals("a\n\nb", adf.to_markdown(nodes))
		end)
	end)
end)
