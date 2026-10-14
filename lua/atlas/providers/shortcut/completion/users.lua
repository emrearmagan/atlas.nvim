local users_api = require("atlas.providers.shortcut.users")

---@type AtlasCompletionSource
return {
	triggers = { "@" },

	complete = function(_, _, done)
		return users_api.list(function(members, err)
			if err then
				done(nil, err)
				return
			end

			local items, seen = {}, {}
			for _, member in ipairs(members) do
				local username = member.username
				if username and username ~= "" and not member.disabled and not seen[username] then
					seen[username] = true
					table.insert(items, {
						label = "@" .. username,
						insert_text = "@" .. username,
						filter_text = username .. " " .. member.name,
						detail = member.name,
					})
				end
			end
			table.sort(items, function(left, right)
				return left.label < right.label
			end)
			done(items, nil)
		end)
	end,
}
