-- Routes to api/cloud/repositories.lua or api/server/repositories.lua
-- based on the active api_type. See api/router.lua.
return require("atlas.pulls.providers.bitbucket.api.router")("repositories")
