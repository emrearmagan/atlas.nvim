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
--         extra_params = { sort = "recentupdate" },
--       },
--     },
--     bookmarks = {
--       key = "S",
--       label = "Search",
--       items = {
--         ["Authentication"] = { search = "authentication" },
--       },
--     },
--   },
-- },

require("atlas.providers.gitea.config")

---@class AtlasGiteaPullsSearchConfig
---@field repo string|nil
---@field search string|nil Global pull request search text. Omit `repo` when using it.
---@field current_repo boolean|nil
---@field extra_params table<string, string|number|boolean>|nil Additional API query parameters.

---@class AtlasGiteaPullsViewConfig : AtlasPullsViewConfig, AtlasGiteaPullsSearchConfig

---@class AtlasGiteaPullsBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasGiteaPullsSearchConfig>|nil

---@class AtlasGiteaPullsConfig
---@field draft_prefix string|nil Enabled server prefix used to mark pull requests as drafts. Defaults to `WIP:`.
---@field views AtlasGiteaPullsViewConfig[]|nil
---@field bookmarks AtlasGiteaPullsBookmarksConfig|nil
