local service = require("atlas.providers.forge.forgejo.api")
local mapper = require("atlas.pulls.providers.forge.api.mapper").new("forgejo")

return {
	checks = require("atlas.pulls.providers.forge.api.checks").new(service),
	commits = require("atlas.pulls.providers.forge.api.commits").new(service),
	files = require("atlas.pulls.providers.forge.api.files").new(service),
	mapper = mapper,
	pullrequests = require("atlas.pulls.providers.forge.api.pullrequests").new(service, mapper),
	repositories = require("atlas.pulls.providers.forge.api.repositories").new(service),
}
