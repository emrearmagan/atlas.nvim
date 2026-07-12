local config = require("atlas.config")
local parser = require("atlas.commands.open.parser")

describe("open parser", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			pulls = {
				providers = {
					github = {},
					gitlab = { base_url = "https://gitlab.example.com" },
					bitbucket = {},
				},
			},
			issues = {
				providers = {
					github = {},
					gitlab = { base_url = "https://gitlab.example.com" },
					jira = { base_url = "https://jira.example.com" },
				},
			},
		}
	end)

	after_each(function()
		config.options = original_options
	end)

	it("parses supported provider URLs", function()
		local github = assert(parser.parse("https://github.com/emrearmagan/atlas.nvim/pull/42"))
		local jira = assert(parser.parse("https://jira.example.com/browse/ATLAS-123"))
		local gitlab = assert(parser.parse("https://gitlab.example.com/emrearmagan/atlas.nvim/-/issues/8"))
		local bitbucket = assert(parser.parse("https://bitbucket.org/emrearmagan/atlas.nvim/pull-requests/7"))

		assert.are.equal("pr", github.entity)
		assert.are.equal(42, github.number)
		assert.are.equal("ATLAS-123", jira.issue_key)
		assert.are.equal("emrearmagan/atlas.nvim", gitlab.project_path)
		assert.are.equal("emrearmagan", bitbucket.workspace)
	end)

	it("recognizes Jira keys and numbers", function()
		assert.are.equal("ATLAS-123", assert(parser.parse_reference("atlas-123")).issue_key)
		assert.are.equal(42, assert(parser.parse_reference("#42")).number)
		local repo = assert(parser.parse_reference("emrearmagan/atlas.nvim#42"))
		assert.are.equal("emrearmagan/atlas.nvim", repo.repo_slug)
		assert.are.equal(42, repo.number)
	end)

	it("rejects unsupported URLs", function()
		local target, err = parser.parse("https://jira.other.example.com/browse/ATLAS-123")
		assert.is_nil(target)
		assert.are.equal("Unsupported Atlas URL", err)

		target, err = parser.parse("https://bitbucket.example.com/projects/ATLAS/repos/atlas.nvim/pull-requests/12")
		assert.is_nil(target)
		assert.are.equal(
			"Bitbucket Server/Data Center URLs are recognized, but this Atlas provider currently supports Bitbucket Cloud only",
			err
		)
	end)
end)
