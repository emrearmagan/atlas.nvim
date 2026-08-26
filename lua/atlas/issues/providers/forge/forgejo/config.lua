require("atlas.providers.forge.forgejo.config")

---@class AtlasForgejoIssuesSearchConfig
---@field repo string|nil Repository-scoped view. Omit to search across repositories.
---@field state "open"|"closed"|"all"|nil
---@field scope "assigned"|"created"|"mentioned"|"all"|nil
---@field search string|nil
---@field labels string|nil
---@field current_repo boolean|nil
---@field extra_params table<string, string|number|boolean>|nil

---@class AtlasForgejoIssuesViewConfig : AtlasIssuesViewConfig, AtlasForgejoIssuesSearchConfig

---@class AtlasForgejoIssuesBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasForgejoIssuesSearchConfig>|nil

---@class AtlasForgejoIssuesConfig
---@field views AtlasForgejoIssuesViewConfig[]|nil
---@field bookmarks AtlasForgejoIssuesBookmarksConfig|nil
