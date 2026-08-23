-- providers = {
--   gitea = {
--     base_url = "https://gitea.example.com",
--     token = vim.env.GITEA_TOKEN,
--     cache_ttl = 300,
--   },
-- },
-- pulls = {
--   gitea = {
--     draft_prefix = "WIP:",
--     views = {
--       {
--         name = "Repository",
--         key = "1",
--         layout = "compact",
--         repo = "owner/repository",
--         search = "authentication",
--       },
--     },
--     bookmarks = {
--       key = "S",
--       label = "Search",
--       items = {
--         ["Authentication"] = { repo = "owner/repository", search = "authentication" },
--       },
--     },
--   },
-- },

require("atlas.providers.gitea.config")

---@class AtlasGiteaPullsSearchConfig
---@field repo string|nil
---@field search string|nil Pull request search text.
---@field current_repo boolean|nil

---@class AtlasGiteaPullsViewConfig : AtlasPullsViewConfig, AtlasGiteaPullsSearchConfig

---@class AtlasGiteaPullsBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasGiteaPullsSearchConfig>|nil

---@class AtlasGiteaPullsConfig
---@field draft_prefix string|nil Enabled server prefix used to mark pull requests as drafts. Defaults to `WIP:`.
---@field views AtlasGiteaPullsViewConfig[]|nil
---@field bookmarks AtlasGiteaPullsBookmarksConfig|nil
