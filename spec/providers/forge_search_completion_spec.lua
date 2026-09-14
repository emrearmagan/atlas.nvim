local MODULE = "atlas.providers.forge.completion.search"
local PROMPT = "atlas.commands.search.prompt"

for _, provider in ipairs({ "gitea", "forgejo" }) do
	for _, domain in ipairs({ "pulls", "issues" }) do
		describe(provider .. " " .. domain .. " search completion", function()
			local previous_module, previous_prompt, options, submissions

			before_each(function()
				previous_module, previous_prompt = package.loaded[MODULE], package.loaded[PROMPT]
				package.loaded[MODULE] = nil
				package.loaded[PROMPT] = {
					open = function(value)
						options = value
					end,
				}
				submissions = {}
				require(MODULE).edit(provider, domain, "repo:owner/repo ", function(value)
					table.insert(submissions, value)
				end)
			end)

			after_each(function()
				package.loaded[MODULE], package.loaded[PROMPT] = previous_module, previous_prompt
			end)

			local function complete(query, cursor)
				local command = options.name .. " "
				return options.complete("ignored", command .. query, #command + (cursor or #query))
			end

			it("uses the shared prompt with the provider and domain command name", function()
				local provider_name = provider == "gitea" and "Gitea" or "Forgejo"
				local suffix = domain == "pulls" and "PullSearch" or "IssueSearch"
				assert.equal("Atlas" .. provider_name .. suffix, options.name)
				assert.equal("repo:owner/repo ", options.default)
				assert.same({}, submissions)
			end)

			it("offers only the domain's supported qualifiers and static values", function()
				local qualifiers = { "is:", "param.", "repo:", "search:", "type:" }
				local states = { "is:all", "is:closed", "is:declined", "is:merged", "is:open" }
				if domain == "issues" then
					qualifiers =
						{ "is:", "label:", "labels:", "param.", "repo:", "scope:", "search:", "state:", "type:" }
					states = { "is:all", "is:closed", "is:open" }
				end
				assert.same(qualifiers, complete(""))
				assert.same(qualifiers, complete("repo:owner/repo\t  "))
				assert.same(states, complete("repo:owner/repo is:"))
				assert.same({ "type:" .. domain }, complete("type:"))
				assert.same({}, complete("param.sort:"))
				assert.same({}, complete("repo:owner/"))
				if domain == "issues" then
					assert.same({ "state:all", "state:closed", "state:open" }, complete("state:"))
					assert.same(
						{ "scope:all", "scope:assigned", "scope:created", "scope:mentioned" },
						complete("scope:")
					)
					assert.same({}, complete("is:merged"))
				else
					assert.same({}, complete("scope:"))
					assert.same({}, complete("state:"))
				end
			end)

			it("matches case-insensitively at the cursor and ignores the text to its right", function()
				assert.same({ "repo:" }, complete("RE"))
				assert.same({ "IS:closed" }, complete("IS:CL"))
				assert.same({ "param." }, complete("PAR"))
				local left = "repo:owner/repo is:cl"
				assert.same({ "is:closed" }, complete(left .. " search:other", #left))
				local command = ":" .. options.name .. " is:o"
				assert.same({ "is:open" }, options.complete("is:o", command, #command))
			end)

			it("does not suggest filters inside literal or quoted values", function()
				for _, input in ipairs({
					"search:is:",
					'search:"some is:',
					[=[search:"say \"hello\" is:]=],
					'"plain is:',
					'labels:"help wanted ',
					'param.custom:"is:',
				}) do
					assert.same({}, complete(input), input)
				end
				assert.same({ "is:open" }, complete([=[search:"say \"hello\"" is:o]=]))
				local quoted = 'search:"look at is:cl now"'
				assert.same({}, complete(quoted, #'search:"look at is:cl'))
			end)

			it("completes comma-separated states only for pull requests", function()
				local expected = domain == "pulls" and { "is:open,merged" } or {}
				assert.same(expected, complete("is:open,me"))
			end)

			it("trims submitted queries and ignores empty submissions", function()
				options.on_submit("")
				options.on_submit(" \t ")
				options.on_submit(nil)
				assert.same({}, submissions)
				options.on_submit("  repo:owner/repo is:open  ")
				assert.same({ "repo:owner/repo is:open" }, submissions)
			end)
		end)
	end
end
