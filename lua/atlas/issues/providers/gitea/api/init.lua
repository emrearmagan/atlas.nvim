return {
	comments = require("atlas.issues.providers.gitea.api.comments"),
	issues = require("atlas.issues.providers.gitea.api.issues"),
	notifications = require("atlas.providers.gitea.notifications").new("issues"),
	timeline = require("atlas.issues.providers.gitea.api.timeline"),
}
