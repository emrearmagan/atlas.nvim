-- Routes to api/cloud/comments.lua or api/server/comments.lua
-- based on the active api_type. See api/router.lua.
return require("atlas.pulls.providers.bitbucket.api.router")("comments")
