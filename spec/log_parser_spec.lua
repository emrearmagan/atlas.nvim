local parser = require("atlas.pulls.pipelines.parser")
local highlights = require("atlas.pulls.pipelines.highlights")
local github = require("atlas.pulls.pipelines.github.parser")
local gitlab = require("atlas.pulls.pipelines.gitlab.parser")
local bamboo = require("atlas.pulls.pipelines.bamboo.parser")
local bitbucket = require("atlas.pulls.pipelines.bitbucket.parser")

describe("pipeline logs", function()
	local original_strptime, original_hlexists

	before_each(function()
		original_strptime, original_hlexists = vim.fn.strptime, vim.fn.hlexists
		vim.fn.strptime = function(_, value)
			local times = {
				["2026-09-20T14:30:12+0000"] = 100,
				["2026-09-20T14:30:15+0000"] = 103,
				["20-Sep-2026 14:30:12"] = 100,
				["20-Sep-2026 14:30:15"] = 103,
			}
			assert.is_not_nil(times[value], value)
			return times[value]
		end
		vim.fn.hlexists = function(name)
			return name == "CustomLog" and 1 or 0
		end
	end)

	after_each(function()
		vim.fn.strptime, vim.fn.hlexists = original_strptime, original_hlexists
	end)

	it("strips BOM, ANSI colors, hyperlinks and controls without changing the raw log", function()
		local raw = "\239\187\191\27[31mError\27[0m\r\n\r\n"
			.. "\27]8;;https://example.com\7link\27]8;;\7\n"
			.. "\27]8;;https://example.com\27\\other\27]8;;\27\\\n  \toutput\0\7\n"
		local log = { raw = raw }
		assert.same({
			{ text = "Error" },
			{ text = "" },
			{ text = "link" },
			{ text = "other" },
			{ text = "  \toutput" },
		}, parser.parse(log))
		assert.equal(raw, log.raw)
		assert.same({}, parser.parse({ raw = "" }))
	end)

	it("extracts timestamps while preserving their original text", function()
		for _, timestamp in ipairs({
			"2026-09-20T14:30:12.123Z",
			"2026-09-20 14:30:12,123",
			"2026-09-20T14:30:12+02:00",
			"2026-09-20T14:30:12.123-0530",
			"2026-09-20 14:30:12",
		}) do
			local text = timestamp .. " Building"
			assert.same({ { text = text, timestamp = timestamp } }, parser.parse({ raw = text }))
		end
		assert.same({ { text = "2026-09-20T14:30:12suffix" } }, parser.parse({ raw = "2026-09-20T14:30:12suffix" }))
	end)

	it("passes cleaned lines to a custom parser and returns its entries", function()
		local log = { raw = "\27[32mBuilding\27[0m" }
		local expected = { { name = "Custom build", entries = { { text = "Building" } } } }
		local entries = parser.parse(log, function(value)
			assert.equal(log, value)
			assert.same({ { text = "Building" } }, value.lines)
			return expected
		end)
		assert.equal(expected, entries)
	end)

	it("parses nested GitHub groups in both marker formats", function()
		for _, markers in ipairs({ { "##[group]", "##[endgroup]" }, { "::group::", "::endgroup::" } }) do
			local entries = parser.parse({
				raw = table.concat({
					"2026-09-20T14:30:12Z " .. markers[1] .. "Build",
					markers[1] .. "Compile",
					"Compiling",
					markers[2],
					"2026-09-20T14:30:15Z " .. markers[2],
					"Done",
				}, "\n"),
			}, github.parse)
			assert.same({
				{
					name = "Build",
					timestamp = "2026-09-20T14:30:12Z",
					duration = 3,
					entries = { { name = "Compile", entries = { { text = "Compiling" } } } },
				},
				{ text = "Done" },
			}, entries)
		end
	end)

	it("keeps echoed colon markers as text when GitHub runner groups exist", function()
		local entries = parser.parse({
			raw = "##[group]Build\n::group::Echoed\n::endgroup::\n##[endgroup]",
		}, github.parse)
		assert.same({
			{ name = "Build", entries = { { text = "::group::Echoed" }, { text = "::endgroup::" } } },
		}, entries)
	end)

	it("reads GitHub action names, status and duration from markers", function()
		local entries = parser.parse({
			raw = table.concat({
				"##[start-action display=Build%3B test%5D%25;id=build]",
				"Compiling",
				"##[end-action id=build;outcome=failure;conclusion=failure;duration_ms=1500]",
			}, "\n"),
		}, github.parse)
		assert.same({
			{ name = "Build; test]%", state = "FAILED", duration = 1.5, entries = { { text = "Compiling" } } },
		}, entries)
	end)

	it("parses GitLab sections and joins continuations from the same stream", function()
		local entries = parser.parse({
			raw = table.concat({
				"\27[0Ksection_start:100:build[collapsed=true]\r\27[0KBuild",
				"00O Compil",
				"00E Warning",
				"00O+ing",
				"section_end:103:build\r",
				"Done",
			}, "\n"),
		}, gitlab.parse)
		assert.same({
			{ name = "Build", duration = 3, entries = { { text = "Compiling" }, { text = "Warning" } } },
			{ text = "Done" },
		}, entries)
	end)

	it("parses Bamboo task results without treating build output as task markers", function()
		for result, state in pairs({ Success = "SUCCESSFUL", Failed = "FAILED" }) do
			local entries = parser.parse({
				raw = table.concat({
					"simple 20-Sep-2026 14:30:12 Starting task 'Build' of type 'script'",
					"build 20-Sep-2026 14:30:12 Starting task 'Echoed' of type 'script'",
					"simple 20-Sep-2026 14:30:15 Finished task 'Build' with result: " .. result,
				}, "\n"),
			}, bamboo.parse)
			assert.same({
				{
					name = "Build",
					timestamp = "20-Sep-2026 14:30:12",
					state = state,
					duration = 3,
					entries = {
						{ text = "Starting task 'Echoed' of type 'script'", timestamp = "20-Sep-2026 14:30:12" },
						{ text = "Finished task 'Build' with result: " .. result, timestamp = "20-Sep-2026 14:30:15" },
					},
				},
			}, entries)
		end
	end)

	it("keeps Bitbucket output flat after shared cleanup", function()
		local log = { raw = "##[group]Build\n\27[32mCompiling\27[0m" }
		local entries = parser.parse(log, bitbucket.parse)
		assert.equal(log.lines, entries)
		assert.same({ { text = "##[group]Build" }, { text = "Compiling" } }, entries)
	end)

	it("applies default highlights and counts only errors and warnings", function()
		local format, counts = highlights.new()
		for _, case in ipairs({
			{ "##[error]Broken", "Error: Broken", "AtlasLogErrorLine", true },
			{ "::error file=a.lua,line=2::Broken", "Error: Broken", "AtlasLogErrorLine", true },
			{ "##[warning]Careful", "Warning: Careful", "AtlasLogWarn" },
			{ "::warning::Careful", "Warning: Careful", "AtlasLogWarn" },
			{ "##[notice]Notice", "Notice: Notice", "AtlasLogInfo" },
			{ "::notice::Notice", "Notice: Notice", "AtlasLogInfo" },
			{ "##[debug]Details", "Debug: Details", "AtlasLogDebug" },
			{ "::debug::Details", "Debug: Details", "AtlasLogDebug" },
			{ "##[command]make", "make", "AtlasLogCommand" },
			{ "[command]make", "make", "AtlasLogCommand" },
			{ "##[section]Build", "Build", "AtlasLogGroup" },
			{ "[ERROR] Broken", "[ERROR] Broken", "AtlasLogError" },
			{ "WARNING: Careful", "WARNING: Careful", "AtlasLogWarn" },
		}) do
			local text, spans = format(case[1], false)
			assert.equal(case[2], text)
			assert.same({ { start_col = 0, end_col = #text, hl_group = case[3], hl_eol = case[4] } }, spans)
		end
		assert.same({ error = 3, warn = 3 }, counts)
		assert.same({ "[ERROR] group", { { start_col = 0, end_col = 13, hl_group = "AtlasLogGroup" } } }, {
			format("[ERROR] group", true),
		})
		assert.same({ error = 3, warn = 3 }, counts)
		assert.same({ "ordinary output", {} }, { format("ordinary output", false) })
	end)

	it("lets the last valid custom rule override defaults and ignores invalid rules", function()
		local format, counts = highlights.new({
			{ pattern = "^Error:", level = "warn" },
			{ pattern = "^Error:", level = "info", hl_group = "CustomLog" },
			{ pattern = "[", level = "error" },
			{ pattern = ".*", level = "invalid" },
			{ pattern = ".*", hl_group = "MissingHighlight" },
		})
		assert.same({ "Error: Broken", { { start_col = 0, end_col = 13, hl_group = "CustomLog" } } }, {
			format("##[error]Broken", false),
		})
		assert.same({ error = 0, warn = 0 }, counts)
	end)
end)
