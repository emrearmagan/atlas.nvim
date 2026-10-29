---@class PullsCreatePROpts
---@field repo_slug string
---@field title string
---@field body string
---@field head string
---@field head_repo_slug string|nil Full name of the repository that owns the head branch when it differs from repo_slug.
---@field base string
---@field draft boolean|nil
---@field reviewers PullsReviewerCandidate[]|nil

---@class PullsCreatePRResult
---@field id string|number|nil
---@field url string|nil
---@field message string|nil

---@class PullsUpdatePROpts
---@field title string|nil
---@field body string|nil
---@field base string|nil
---@field draft boolean|nil
---@field reviewers PullsReviewerCandidate[]|nil
---@field labels string[]|nil
---@field assignees AtlasUser[]|nil

return {
	open = require("atlas.pulls.editor.create").open,
	edit = require("atlas.pulls.editor.edit").open,
}
