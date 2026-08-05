-- Routes to api/cloud/pullrequests.lua or api/server/pullrequests.lua
-- based on the active api_type. See api/router.lua.
return require("atlas.pulls.providers.bitbucket.api.router")("pullrequests")
