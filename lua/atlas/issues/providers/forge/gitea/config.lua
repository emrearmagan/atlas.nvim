require("atlas.providers.forge.gitea.config")

---@class AtlasGiteaIssuesSearchConfig
---@field repo string|nil Repository-scoped view. Omit to search across repositories.
---@field state "open"|"closed"|"all"|nil
---@field scope "assigned"|"created"|"mentioned"|"all"|nil
---@field search string|nil
---@field labels string|nil
---@field current_repo boolean|nil
---@field extra_params table<string, string|number|boolean>|nil

---@class AtlasGiteaIssuesViewConfig : AtlasIssuesViewConfig, AtlasGiteaIssuesSearchConfig

---@class AtlasGiteaIssuesBookmarkConfig : AtlasIssuesBookmarkConfig, AtlasGiteaIssuesSearchConfig

---@class AtlasGiteaIssuesBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, string|AtlasGiteaIssuesBookmarkConfig>|nil

---@class AtlasGiteaIssuesConfig
---@field views AtlasGiteaIssuesViewConfig[]|nil
---@field bookmarks AtlasGiteaIssuesBookmarksConfig|nil
