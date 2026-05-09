---@class AtlasGitHubViewConfig : AtlasPullsViewConfig
---@field search string

---@class AtlasGitHubConfig
---@field cache_ttl number|nil
---@field pr_template string|nil Defaults to ".github/pull_request_template.md"
---@field views AtlasGitHubViewConfig[]|nil
