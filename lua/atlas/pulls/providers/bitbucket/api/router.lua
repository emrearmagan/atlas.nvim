local service = require("atlas.pulls.providers.bitbucket.api.service")

-- Route each API module to its Cloud or Server implementation.
return function(module)
	return require(string.format("atlas.pulls.providers.bitbucket.api.%s.%s", service.api_type(), module))
end
