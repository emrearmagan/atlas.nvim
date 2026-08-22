-- One Atlas provider supports both API implementations:
--
-- gitea = {
--   api_type = "gitea", -- or "forgejo"
--   base_url = "https://git.example.com",
--   token = vim.env.GITEA_TOKEN,
--   cache_ttl = 300,
--   draft_prefix = "WIP:",
--   views = {
--     {
--       name = "Repository",
--       key = "1",
--       layout = "compact",
--       repo = "owner/repository",
--       search = "authentication",
--     },
--   },
--   bookmarks = {
--     key = "S",
--     label = "Search",
--     items = {
--       ["Authentication"] = { repo = "owner/repository", search = "authentication" },
--     },
--   },
-- }

require("atlas.providers.gitea.config")

---@class AtlasGiteaForgejoPullsSearchConfig
---@field repo string|nil
---@field search string|nil Pull request search text.

---@class AtlasGiteaForgejoPullsViewConfig : AtlasPullsViewConfig, AtlasGiteaForgejoPullsSearchConfig

---@class AtlasGiteaForgejoPullsBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasGiteaForgejoPullsSearchConfig>|nil

---@class AtlasGiteaPullsConfig : AtlasGiteaForgejoConfig
---@field api_type "gitea"|nil Defaults to Gitea.
---@field draft_prefix string|nil Enabled server prefix used to mark pull requests as drafts. Defaults to `WIP:`.
---@field views AtlasGiteaForgejoPullsViewConfig[]|nil
---@field bookmarks AtlasGiteaForgejoPullsBookmarksConfig|nil

---@class AtlasForgejoPullsConfig : AtlasGiteaForgejoConfig
---@field api_type "forgejo"
---@field draft_prefix string|nil Enabled server prefix used to mark pull requests as drafts. Defaults to `WIP:`.
---@field views AtlasGiteaForgejoPullsViewConfig[]|nil
---@field bookmarks AtlasGiteaForgejoPullsBookmarksConfig|nil

---@alias AtlasGiteaForgejoPullsConfig AtlasGiteaPullsConfig|AtlasForgejoPullsConfig
