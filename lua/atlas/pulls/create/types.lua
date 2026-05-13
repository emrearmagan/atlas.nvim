---@class PullsCreatePRReviewer
---@field label string
---@field provider_id string
---@field selected boolean|nil
---@field default boolean|nil

---@class PullsCreatePROpts
---@field repo_slug string
---@field title string
---@field body string
---@field head string
---@field base string
---@field draft boolean|nil
---@field repo_root string|nil
---@field reviewers PullsCreatePRReviewer[]|nil

---@class PullsCreatePRResult
---@field id string|number|nil
---@field url string|nil
---@field message string|nil

return {}
