local preview = require("atlas.ui.components.code_preview")

local function syntax_spans(result)
	local spans = {}
	for _, span in ipairs(result.highlights) do
		if span.hl_group and span.hl_group:sub(1, 1) == "@" then
			spans[#spans + 1] = span
		end
	end
	return spans
end

describe("ui.components.code_preview", function()
	local original_filetype, original_treesitter
	local captures, parsed_source, parsed_language

	before_each(function()
		original_filetype, original_treesitter = vim.filetype, vim.treesitter
		captures = { { "keyword", { 0, 0, 0, 0, 5, 5 } } }
		parsed_source, parsed_language = nil, nil
		vim.filetype = {
			match = function(opts)
				local extension = opts.filename:match("%.([^.]*)$")
				return ({
					lua = "lua",
					js = "javascript",
					jsx = "javascriptreact",
					ts = "typescript",
					tsx = "typescriptreact",
					sh = "sh",
					bash = "sh",
					latex = "tex",
					cs = "cs",
				})[extension]
			end,
		}
		vim.treesitter = {
			language = {
				get_lang = function(filetype)
					return ({
						js = "javascript",
						jsx = "javascript",
						javascriptreact = "javascript",
						ts = "typescript",
						typescriptreact = "tsx",
						sh = "bash",
						tex = "latex",
						cs = "c_sharp",
					})[filetype]
				end,
			},
			get_string_parser = function(source, language)
				parsed_source, parsed_language = source, language
				return {
					parse = function()
						return { { root = function() end } }
					end,
				}
			end,
			get_range = function(node, _, metadata)
				return metadata and metadata.range or node
			end,
			query = {
				get = function()
					local names = {}
					for id, capture in ipairs(captures) do
						names[id] = capture[1]
					end
					return {
						captures = names,
						iter_captures = function()
							local id = 0
							return function()
								id = id + 1
								local capture = captures[id]
								if capture then
									return id, capture[2], { [id] = capture[3] }
								end
							end
						end,
					}
				end,
			},
		}
	end)

	after_each(function()
		vim.filetype, vim.treesitter = original_filetype, original_treesitter
	end)

	it("preserves numbered previews, selection and custom backgrounds", function()
		for _, name in ipairs({ "_private", "spell", "nospell" }) do
			captures[#captures + 1] = { name, captures[1][2] }
		end
		local result = preview.render({
			file_path = "src/main.lua",
			lines = { "local x = 1", "print(x)", "return x" },
			start_line = 8,
			line_numbers = { 12, 123, 124 },
			anchor_start = 8,
			anchor_line = 9,
			padding = 2,
			background_hl_group = "AtlasDiffChangeLine",
		})
		assert.same({ " 12    local x = 1  ", "123    print(x)  ", "124    return x  " }, result.lines)
		assert.equals("local x = 1\nprint(x)\nreturn x", parsed_source)
		assert.equals("AtlasDiffChangeLine", result.highlights[1].line_hl_group)
		assert.equals("CursorLineNr", result.highlights[2].hl_group)
		assert.equals("CursorLineNr", result.highlights[4].hl_group)
		assert.equals("AtlasTextMuted", result.highlights[6].hl_group)
		assert.same({ { line = 0, start_col = 7, end_col = 12, hl_group = "@keyword.lua" } }, syntax_spans(result))
	end)

	it("pads code with or without line numbers and retains the shared background", function()
		for _, case in ipairs({
			{ true, { "1    local x = 1  ", "2      " }, 5 },
			{ false, { "  local x = 1  ", "    " }, 2 },
		}) do
			local result = preview.render({
				lines = { "local x = 1", "" },
				language = "lua",
				show_line_numbers = case[1],
				padding = 2,
			})
			assert.same(case[2], result.lines)
			assert.equals("AtlasCodeBackground", result.highlights[1].line_hl_group)
			assert.same({
				{ line = 0, start_col = case[3], end_col = case[3] + 5, hl_group = "@keyword.lua" },
			}, syntax_spans(result))
		end
	end)

	it("wraps unnumbered code while preserving syntax and backgrounds", function()
		captures = {
			{ "keyword", { 0, 0, 0, 0, 5, 5 } },
			{ "variable", { 0, 6, 6, 0, 11, 11 } },
		}
		local result = preview.render({
			lines = { "local value", "" },
			language = "lua",
			show_line_numbers = false,
			padding = 1,
			width = 8,
		})
		assert.same({ " local ", " value ", "  " }, result.lines)
		assert.equals("local value\n", parsed_source)
		assert.same({
			{ line = 0, line_hl_group = "AtlasCodeBackground" },
			{ line = 1, line_hl_group = "AtlasCodeBackground" },
			{ line = 2, line_hl_group = "AtlasCodeBackground" },
			{ line = 0, start_col = 1, end_col = 6, hl_group = "@keyword.lua" },
			{ line = 1, start_col = 1, end_col = 6, hl_group = "@variable.lua" },
		}, result.highlights)
		assert.same({ "1  local value", "2  " }, preview.render({ lines = { "local value", "" }, width = 8 }).lines)
	end)

	it("uses registered language mappings and preserves explicit parser names", function()
		for alias, language in pairs({
			js = "javascript",
			jsx = "javascript",
			ts = "typescript",
			tsx = "tsx",
			sh = "bash",
			bash = "bash",
			latex = "latex",
			cs = "c_sharp",
		}) do
			preview.render({ lines = { "code" }, language = alias, file_path = "wrong.lua" })
			assert.equals(language, parsed_language)
		end

		vim.treesitter.language.get_lang = function(filetype)
			return filetype == "js" and "custom_parser" or filetype
		end
		preview.render({ lines = { "code" }, language = "js" })
		assert.equals("custom_parser", parsed_language)
	end)

	it("applies capture metadata and splits multiline Unicode into byte ranges", function()
		captures = { { "comment", { 0, 0, 0, 3, 3, 21 }, { range = { 0, 3, 3, 3, 0, 18 } } } }
		local result = preview.render({
			lines = { "-- café", "mañana", "", "fin" },
			language = "lua",
			show_line_numbers = false,
			padding = 2,
		})
		assert.same({
			{ line = 0, start_col = 5, end_col = 10, hl_group = "@comment.lua" },
			{ line = 1, start_col = 2, end_col = 9, hl_group = "@comment.lua" },
		}, syntax_spans(result))
	end)

	it("keeps code visible without a language, parser or highlight query", function()
		local opts = { lines = { "local x = 1" }, show_line_numbers = false }
		local plain = preview.render(opts)
		assert.same({ "local x = 1" }, plain.lines)
		assert.same({}, syntax_spans(plain))
		assert.is_nil(parsed_source)

		opts.language = "lua"
		vim.treesitter.query.get = function() end
		assert.same(plain, preview.render(opts))
		vim.treesitter.get_string_parser = function()
			error("Parser unavailable")
		end
		assert.same(plain, preview.render(opts))
	end)

	it("does not hide query or parser execution errors", function()
		local opts = { lines = { "local x = 1" }, language = "lua" }
		vim.treesitter.query.get = function()
			error("Invalid query", 0)
		end
		assert.has_error(function()
			preview.render(opts)
		end, "Invalid query")
		vim.treesitter.get_string_parser = function()
			return {
				parse = function()
					error("Parse error", 0)
				end,
			}
		end
		assert.has_error(function()
			preview.render(opts)
		end, "Parse error")
	end)
end)
