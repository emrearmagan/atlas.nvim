-- Routes to api/cloud/users.lua or api/server/users.lua
-- based on the active api_type. See api/router.lua.
return require("atlas.pulls.providers.bitbucket.api.router")("users")
