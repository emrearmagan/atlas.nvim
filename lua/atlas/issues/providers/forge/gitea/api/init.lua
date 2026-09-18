local service = require("atlas.providers.forge.gitea.api")
local mapper = require("atlas.issues.providers.forge.api.mapper").new("gitea")

return {
	comments = require("atlas.issues.providers.forge.api.comments").new(service, mapper),
	issues = require("atlas.issues.providers.forge.api.issues").new(service, mapper),
	mapper = mapper,
	timeline = require("atlas.issues.providers.forge.api.timeline").new(service, mapper),
}
