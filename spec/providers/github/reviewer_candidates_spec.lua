local github_client = require("spec.support.github_client_stub")

local MODULE = "atlas.pulls.providers.github.api.pullrequests"
local REVIEWS = "atlas.pulls.providers.github.api.reviews"

describe("github reviewer candidates", function()
	local original_reviews

	---@param collaborators table|nil
	---@param err string|nil
	---@param current table[]|nil
	---@return PullsReviewerCandidate[]|nil, string|nil
	local function fetch(collaborators, err, current)
		github_client.install({
			gh = function(_, callback)
				callback(collaborators, err)
			end,
		})
		package.loaded[REVIEWS] = {
			fetch_reviewers = function(_, _, done)
				done(current, nil)
			end,
		}
		package.loaded[MODULE] = nil

		local reviewers, failure
		require(MODULE).fetch_reviewer_candidates(
			{ repo_slug = "owner/repo", pr = current and { id = 1 } or nil },
			function(items, fetch_err)
				reviewers, failure = items, fetch_err
			end
		)
		return reviewers, failure
	end

	before_each(function()
		original_reviews = package.loaded[REVIEWS]
	end)

	after_each(function()
		github_client.uninstall()
		package.loaded[REVIEWS] = original_reviews
		package.loaded[MODULE] = nil
	end)

	it("selects current reviewers and adds the ones who are not collaborators", function()
		local reviewers = fetch({ { { login = "alice" }, { login = "bob" } } }, nil, {
			{ role = "reviewer", username = "bob" },
			{ role = "reviewer", username = "carol" },
			{ role = "author", username = "alice" },
		})

		assert.same({
			{ label = "@alice", provider_id = "alice", selected = false },
			{ label = "@bob", provider_id = "bob", selected = true },
			{ label = "@carol", provider_id = "carol", selected = true },
		}, reviewers)
	end)

	it("explains a missing push access instead of showing the raw error", function()
		local reviewers, err = fetch(nil, "gh: Must have push access to view repository collaborators. (HTTP 403)")

		assert.is_nil(reviewers)
		assert.equal("Reviewer suggestions require push access to owner/repo", err)
	end)
end)
