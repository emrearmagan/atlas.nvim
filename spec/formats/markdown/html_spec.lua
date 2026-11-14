local html = require("atlas.formats.markdown.html")

describe("HTML parsing", function()
	it("parses quoted image attributes and consumes only the tag", function()
		for _, tag in ipairs({ '<img src="image.png" alt="logo">', "<img alt='logo' src='image.png' />" }) do
			local fragment, consumed = html.inline.image(tag .. " after")
			assert.same({ text = "󰋩 logo", style = "image", url = "image.png" }, fragment)
			assert.equal(#tag, consumed)
		end
	end)

	it("defaults empty or missing image labels", function()
		for _, tag in ipairs({ '<img src="image.png">', '<img src="image.png" alt="">' }) do
			assert.same({ text = "󰋩 image", style = "image", url = "image.png" }, html.inline.image(tag))
		end
	end)

	it("keeps inline comments literal and stops at the closing marker", function()
		local comment = "<!-- **café** -->"
		local fragment, consumed = html.inline.comment(comment .. " text <!-- next -->")
		assert.same({ text = comment, style = "comment" }, fragment)
		assert.equal(#comment, consumed)
	end)

	it("consumes block comments through the complete closing line", function()
		local rows, next_index = html.block.comment({ "before", "  <!--", "", "--> **raw**", "after" }, 2)
		assert.same({
			{ { text = "  <!--", style = "comment" } },
			{ { text = "", style = "comment" } },
			{ { text = "--> **raw**", style = "comment" } },
		}, rows)
		assert.equal(5, next_index)
	end)

	it("preserves unclosed block comments through EOF", function()
		local rows, next_index = html.block.comment({ "<!--", "**raw**" }, 1)
		assert.same({
			{ { text = "<!--", style = "comment" } },
			{ { text = "**raw**", style = "comment" } },
		}, rows)
		assert.equal(3, next_index)
	end)

	it("skips lines made only of tags without content", function()
		for _, tag in ipairs({
			'<a id="github"></a>',
			"  <a id='github'> </a>  ",
			'<p align="center">',
			"  </p>  ",
			"<details>",
			"</details>",
			"<picture>",
			"<tr><td>",
		}) do
			local rows, next_index = html.block.tags({ "before", tag, "after" }, 2)
			assert.same({}, rows)
			assert.equal(3, next_index)
		end
	end)

	it("renders summary text with an expanded icon", function()
		local summary =
			'<summary><strong>Using <a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></strong></summary>'
		local rows, next_index = html.block.summary({ "before", summary, "after" }, 2)
		assert.same({ { { text = "▾ Using lazy.nvim" } } }, rows)
		assert.equal(3, next_index)
	end)

	it("renders standalone heading tags as headings", function()
		local rows, next_index = html.block.heading({ "<h3>PR <b>Summary</b></h3>" }, 1)
		assert.equal("heading_3", rows[1].hl)
		assert.same({ text = "Summary", style = "strong" }, rows[1][2])
		assert.equal(2, next_index)
		assert.is_nil(html.block.heading({ "<h3>unclosed" }, 1))
	end)

	it("decodes named and numeric entities", function()
		assert.same({ { text = " " }, 6 }, { html.inline.entity("&nbsp;x") })
		assert.same({ { text = "–" }, 7 }, { html.inline.entity("&ndash;") })
		assert.same({ { text = "é" }, 6 }, { html.inline.entity("&#233;") })
		assert.same({ { text = "—" }, 8 }, { html.inline.entity("&#x2014;") })
	end)

	it("keeps styled and linked tag content", function()
		local tag = '<a href="https://example.com/?a=1&amp;b=2">file.py</a>'
		assert.same(
			{ { text = "file.py", style = "link", url = "https://example.com/?a=1&b=2" }, #tag },
			{ html.inline.tag(tag .. " after") }
		)
		assert.same({ { text = "TOTAL", style = "strong" }, 12 }, { html.inline.tag("<b>TOTAL</b>") })
		assert.same({ { text = "x()", style = "inline_code" }, 16 }, { html.inline.tag("<code>x()</code>") })
		assert.same({ { text = "anchor" }, 20 }, { html.inline.tag('<a id="x">anchor</a> b') })
	end)

	it("drops other known tags", function()
		assert.same({ { text = "" }, 6 }, { html.inline.tag("<span>text</span>") })
		assert.same({ { text = "" }, 7 }, { html.inline.tag("</span>") })
		assert.same({ { text = " " }, 5 }, { html.inline.tag("<br/>") })
		assert.same({ { text = "" }, 14 }, { html.inline.tag("<td colspan=2>") })
	end)

	it("moves block-level tags onto their own lines", function()
		assert.same(
			{
				"<!-- marker -->",
				"<p>",
				'<img src="badge.svg">',
				"</p>",
				"<details>",
				"<summary>Report</summary>",
				"<table><tr><td><p>a</p></td></tr></table>",
				"</details>",
			},
			html.split_blocks({
				'<!-- marker --><p><img src="badge.svg"></p><details><summary>Report</summary><table><tr><td><p>a</p></td></tr></table></details>',
			})
		)
		assert.same({ "80%", "<details>" }, html.split_blocks({ "80%<details>" }))
		assert.same({ "> text", "> <details>" }, html.split_blocks({ "> text<details>" }))
	end)

	it("leaves code, comments and table rows unsplit", function()
		local lines = {
			"use `<details>` here",
			"<!-- <details> -->",
			"| a | <p>b</p> |",
			"```html",
			"<p><details>",
			"```",
		}
		assert.same(lines, html.split_blocks(lines))
	end)

	it("renders HTML tables with headers and spanned cells", function()
		local rows, next_index = html.block.table({
			"<table>",
			"<tr><th>File</th><th>Cover</th></tr>",
			'<tbody><tr><td colspan="2"><b>src</b></td></tr>',
			'<tr><td>&nbsp; &nbsp;<a href="a.py">a.py</a></td><td>98%</td></tr></tbody>',
			"</table>",
			"after",
		}, 1, {})

		local lines = {}
		for _, row in ipairs(rows) do
			local text = {}
			for _, fragment in ipairs(row) do
				text[#text + 1] = fragment.text
			end
			lines[#lines + 1] = table.concat(text)
		end

		assert.same({
			"|---------|-------|",
			"| File    | Cover |",
			"|---------|-------|",
			"| src     |       |",
			"|    a.py | 98%   |",
			"|---------|-------|",
		}, lines)
		assert.equal(6, next_index)
	end)

	it("declines unsupported or incomplete input", function()
		assert.is_nil(html.inline.image("![logo](image.png)"))
		assert.is_nil(html.inline.image('<img alt="logo">'))
		assert.is_nil(html.inline.image('<img src="">'))
		assert.is_nil(html.inline.image('<img src="image.png"'))
		assert.is_nil(html.inline.comment("plain text"))
		assert.is_nil(html.inline.comment("<!-- unfinished"))
		assert.is_nil(html.inline.entity("&unknown;"))
		assert.is_nil(html.inline.entity("& amp;"))
		assert.is_nil(html.inline.tag("<String>"))
		assert.is_nil(html.inline.tag("<b-x>"))
		assert.is_nil(html.inline.tag("a < b"))
		assert.is_nil(html.block.comment({ "text <!-- inline -->" }, 1))
		assert.is_nil(html.block.tags({ '<a href="url">text</a>' }, 1))
		assert.is_nil(html.block.tags({ '<a id="github"></a> text' }, 1))
		assert.is_nil(html.block.tags({ "<p>text</p>" }, 1))
		assert.is_nil(html.block.tags({ '<p><img src="logo.png"></p>' }, 1))
		assert.is_nil(html.block.summary({ "<summary>unfinished" }, 1))
		assert.is_nil(html.block.table({ "<table><tr><td>unclosed" }, 1, {}))
	end)
end)
