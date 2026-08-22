-- providers = {
--   forgejo = {
--     base_url = "https://forgejo.example.com",
--     token = vim.env.FORGEJO_TOKEN,
--     cache_ttl = 300,
--   },
-- },
-- pulls = {
--   forgejo = {
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

require("atlas.providers.forgejo.config")

---@class AtlasForgejoPullsSearchConfig
---@field repo string|nil
---@field search string|nil Pull request search text.

---@class AtlasForgejoPullsViewConfig : AtlasPullsViewConfig, AtlasForgejoPullsSearchConfig

---@class AtlasForgejoPullsBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasForgejoPullsSearchConfig>|nil

---@class AtlasForgejoPullsConfig
---@field draft_prefix string|nil Enabled server prefix used to mark pull requests as drafts. Defaults to `WIP:`.
---@field views AtlasForgejoPullsViewConfig[]|nil
---@field bookmarks AtlasForgejoPullsBookmarksConfig|nil
