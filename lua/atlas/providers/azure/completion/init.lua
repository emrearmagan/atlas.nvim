---@type table<string, AtlasCompletionSource>
return {
	users = require("atlas.providers.azure.completion.users"),
	issues = require("atlas.providers.azure.completion.issues"),
	pulls = require("atlas.providers.azure.completion.pulls"),
}
