-- Routes to api/cloud/pipelines.lua or api/server/pipelines.lua
-- based on the active api_type. See api/router.lua.
return require("atlas.pulls.providers.bitbucket.api.router")("pipelines")
