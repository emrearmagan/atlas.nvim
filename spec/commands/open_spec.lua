describe("commands.open", function()
	local command
	local repository
	local resolved
	local pull_result
	local pull_error
	local issue_result
	local issue_error
	local calls
	local original_loaded
	local original_trim

	local mocked_modules = {
		"atlas.commands.open",
		"atlas.config",
		"atlas.core.git",
		"atlas.core.notify",
		"atlas.providers",
		"atlas",
		"atlas.pulls.ui.detail",
		"atlas.issues.ui.detail",
	}

	before_each(function()
		original_loaded = {}
		for _, name in ipairs(mocked_modules) do
			original_loaded[name] = package.loaded[name]
		end
		original_trim = vim.trim
		vim.trim = function(value)
			return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
		end

		repository = nil
		resolved = {}
		pull_result = nil
		pull_error = "Pull request not found"
		issue_result = nil
		issue_error = "Issue not found"
		calls = {
			resolve = {},
			fetch = {},
			dashboard = {},
			pull_detail = {},
			issue_detail = {},
			errors = {},
			local_repository = 0,
		}

		local pull_provider = {
			view_for_target = function(target)
				return { target = target }
			end,
			capabilities = {
				core = {
					fetch_by_refs = function(refs, opts, done)
						local ref = refs[1]
						table.insert(calls.fetch, { domain = "pulls", ref = ref, opts = opts })
						done(pull_result and { pull_result } or {}, pull_error)
					end,
				},
			},
		}
		local issue_provider = {
			issue_ref = function(target)
				return { key = "ISSUE-" .. tostring(target.number) }
			end,
			capabilities = {
				core = {
					fetch_by_refs = function(refs, opts, done)
						local ref = refs[1]
						table.insert(calls.fetch, { domain = "issues", ref = ref, opts = opts })
						done(issue_result and { issue_result } or {}, issue_error)
					end,
				},
			},
		}

		package.loaded["atlas.core.git"] = {
			local_repository = function()
				calls.local_repository = calls.local_repository + 1
				return repository
			end,
		}
		package.loaded["atlas.core.notify"] = {
			error = function(message)
				table.insert(calls.errors, message)
			end,
		}
		package.loaded["atlas.config"] = {
			provider_options = function()
				return {}
			end,
		}
		package.loaded["atlas.providers"] = {
			resolve = function(value)
				table.insert(calls.resolve, value)
				local target = resolved[value]
				return target, target and nil or "Unsupported Atlas target"
			end,
			domain = function(_, domain)
				return domain == "pulls" or domain == "issues"
			end,
			load = function(_, domain)
				return domain == "pulls" and pull_provider or issue_provider
			end,
		}
		package.loaded["atlas"] = {
			open = function(domain, provider, opts)
				table.insert(calls.dashboard, { domain = domain, provider = provider, opts = opts })
			end,
		}
		package.loaded["atlas.pulls.ui.detail"] = {
			open = function(entity, opts)
				table.insert(calls.pull_detail, { entity = entity, opts = opts })
			end,
		}
		package.loaded["atlas.issues.ui.detail"] = {
			open = function(entity, opts)
				table.insert(calls.issue_detail, { entity = entity, opts = opts })
			end,
		}
		package.loaded["atlas.commands.open"] = nil
		command = require("atlas.commands.open")
	end)

	after_each(function()
		vim.trim = original_trim
		for _, name in ipairs(mocked_modules) do
			package.loaded[name] = original_loaded[name]
		end
	end)

	it("routes a direct target to detail as a pull request ref", function()
		local value = "https://github.com/owner/repo/pull/42"
		local target = {
			provider = "github",
			domain = "pulls",
			entity = "pr",
			id = 42,
			number = 42,
			repo_full_name = "owner/repo",
		}
		resolved[value] = target

		command.open(value)

		assert.same({ value }, calls.resolve)
		assert.are.equal(0, #calls.fetch)
		assert.same({ id = 42, repo_full_name = "owner/repo" }, calls.pull_detail[1].entity)
	end)

	it("opens dot as the current repository dashboard", function()
		repository = {
			provider = "github",
			domain = "pulls",
			entity = "repo",
			host = "github.com",
			repo_full_name = "owner/repo",
			url = "https://github.com/owner/repo",
		}

		command.open(".")

		assert.are.equal("pulls", calls.dashboard[1].domain)
		assert.are.equal("github", calls.dashboard[1].provider)
		assert.are.equal(repository, calls.dashboard[1].opts.initial_view.target)
	end)

	it("resolves a number against the current repository with PR priority", function()
		repository = {
			provider = "github",
			domain = "pulls",
			entity = "repo",
			host = "github.com",
			repo_full_name = "owner/repo",
		}
		pull_result = { id = 42, title = "PR" }

		command.open("#42")

		assert.are.equal(0, #calls.resolve)
		assert.are.equal(1, #calls.fetch)
		assert.same({ "pulls" }, { calls.fetch[1].domain })
		assert.are.equal(pull_result, calls.pull_detail[1].entity)
		assert.are.equal(0, #calls.issue_detail)
	end)

	it("falls back from a missing PR to the issue in the same repository", function()
		repository = {
			provider = "github",
			domain = "pulls",
			entity = "repo",
			host = "github.com",
			repo_full_name = "owner/repo",
		}
		issue_result = { key = "ISSUE-42", title = "Issue" }

		command.open("42")

		assert.same({ "pulls", "issues" }, { calls.fetch[1].domain, calls.fetch[2].domain })
		assert.are.equal(issue_result, calls.issue_detail[1].entity)
	end)

	it("requires local repository context for a number", function()
		command.open("42")

		assert.are.equal(0, #calls.resolve)
		assert.are.equal("A numeric reference requires a supported local Git repository", calls.errors[1])
	end)

	it("does not give owner/repo#number special repository handling", function()
		command.open("owner/repo#42")

		assert.same({ "owner/repo#42" }, calls.resolve)
		assert.are.equal(0, calls.local_repository)
		assert.are.equal("Unsupported Atlas target", calls.errors[1])
	end)
end)
