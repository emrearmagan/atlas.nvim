local html = require("atlas.formats.markdown.html")

describe("HTML parsing", function()
	it("parses quoted image attributes and consumes only the tag", function()
		for _, tag in ipairs({ '<img src="image.png" alt="logo">', "<img alt='logo' src='image.png' />" }) do
			local fragment, consumed = html.inline.image(tag .. " after")
			assert.same({ text = "󰋩 logo", style = "image", url = "image.png" }, fragment)
			assert.equals(#tag, consumed)
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
		assert.equals(#comment, consumed)
	end)

	it("consumes block comments through the complete closing line", function()
		local rows, next_index = html.block.comment({ "before", "  <!--", "", "--> **raw**", "after" }, 2)
		assert.same({
			{ { text = "  <!--", style = "comment" } },
			{ { text = "", style = "comment" } },
			{ { text = "--> **raw**", style = "comment" } },
		}, rows)
		assert.equals(5, next_index)
	end)

	it("preserves unclosed block comments through EOF", function()
		local rows, next_index = html.block.comment({ "<!--", "**raw**" }, 1)
		assert.same({
			{ { text = "<!--", style = "comment" } },
			{ { text = "**raw**", style = "comment" } },
		}, rows)
		assert.equals(3, next_index)
	end)

	it("skips standalone empty anchors", function()
		for _, tag in ipairs({ '<a id="github"></a>', "  <a id='github'> </a>  " }) do
			local rows, next_index = html.block.anchor({ "before", tag, "after" }, 2)
			assert.same({}, rows)
			assert.equals(3, next_index)
		end
	end)

	it("skips standalone paragraph tags", function()
		for _, tag in ipairs({ "<p>", '<p align="center">', "  </p>  " }) do
			local rows, next_index = html.block.paragraph({ "before", tag, "after" }, 2)
			assert.same({}, rows)
			assert.equals(3, next_index)
		end
	end)

	it("skips standalone details tags", function()
		for _, tag in ipairs({ "<details>", "  </details>  " }) do
			local rows, next_index = html.block.details({ "before", tag, "after" }, 2)
			assert.same({}, rows)
			assert.equals(3, next_index)
		end
	end)

	it("renders summary text with an expanded icon", function()
		local summary =
			'<summary><strong>Using <a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></strong></summary>'
		local rows, next_index = html.block.summary({ "before", summary, "after" }, 2)
		assert.same({ { { text = "▾ Using lazy.nvim" } } }, rows)
		assert.equals(3, next_index)
	end)

	it("declines unsupported or incomplete input", function()
		assert.is_nil(html.inline.image("![logo](image.png)"))
		assert.is_nil(html.inline.image('<img alt="logo">'))
		assert.is_nil(html.inline.image('<img src="">'))
		assert.is_nil(html.inline.image('<img src="image.png"'))
		assert.is_nil(html.inline.comment("plain text"))
		assert.is_nil(html.inline.comment("<!-- unfinished"))
		assert.is_nil(html.block.comment({ "text <!-- inline -->" }, 1))
		assert.is_nil(html.block.anchor({ '<a href="url">text</a>' }, 1))
		assert.is_nil(html.block.anchor({ '<a id="github"></a> text' }, 1))
		assert.is_nil(html.block.paragraph({ "<p>text</p>" }, 1))
		assert.is_nil(html.block.paragraph({ "<picture>" }, 1))
		assert.is_nil(html.block.details({ "<details>text</details>" }, 1))
		assert.is_nil(html.block.summary({ "<summary>unfinished" }, 1))
	end)
end)
