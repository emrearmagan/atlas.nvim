---@class AtlasAzureIssuesViewConfig : IssuesViewConfig
---@field project string Azure DevOps project name.
---@field search string Native flat WIQL query.

---@class AtlasAzureIssuesBookmarkConfig : AtlasIssuesBookmarkConfig
---@field project string
---@field search string

---@class AtlasAzureIssuesBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasAzureIssuesBookmarkConfig>|nil

---@class AtlasAzureIssuesConfig
---@field views AtlasAzureIssuesViewConfig[]|nil
---@field bookmarks AtlasAzureIssuesBookmarksConfig|nil
