local utils = require("atlas.ui.shared.utils")

describe("UI utils", function()
	it("keeps link URLs on highlights split by wrapping", function()
		local content = utils.wrap_content({
			lines = { "see linked text" },
			highlights = {
				{ line = 0, start_col = 4, end_col = 15, hl_group = "AtlasMarkdownLink", url = "https://example.com" },
			},
		}, 10, "> ")

		local links = vim.tbl_filter(function(span)
			return span.url ~= nil
		end, content.highlights)
		assert.same({
			{ line = 0, start_col = 6, end_col = 12, hl_group = "AtlasMarkdownLink", url = "https://example.com" },
			{ line = 1, start_col = 2, end_col = 7, hl_group = "AtlasMarkdownLink", url = "https://example.com" },
		}, links)
	end)

	it("keeps link URLs when appending blocks", function()
		local lines, spans = { "header" }, {}
		utils.append_block(lines, spans, {
			lines = { "link" },
			highlights = { { line = 0, start_col = 0, end_col = 4, hl_group = "AtlasMarkdownLink", url = "a.py" } },
		}, 2)
		assert.same({ { line = 1, start_col = 2, end_col = 6, hl_group = "AtlasMarkdownLink", url = "a.py" } }, spans)
	end)
end)
