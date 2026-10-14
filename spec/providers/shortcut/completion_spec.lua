describe("Shortcut user completion", function()
	local module_name = "atlas.providers.shortcut.completion.users"
	local users_name = "atlas.providers.shortcut.users"
	local saved_module, saved_users, done

	before_each(function()
		saved_module, saved_users = package.loaded[module_name], package.loaded[users_name]
		package.loaded[module_name] = nil
		package.loaded[users_name] = {
			list = function(callback)
				done = callback
			end,
		}
	end)

	after_each(function()
		package.loaded[module_name], package.loaded[users_name] = saved_module, saved_users
	end)

	it("filters duplicate, disabled and missing handles from mention candidates", function()
		local items
		require(module_name).complete({}, "", function(value)
			items = value
		end)
		done({
			{ id = "owner", name = "Ada Owner", username = "ada.owner" },
			{ id = "duplicate", name = "Ada Owner", username = "ada.owner" },
			{ id = "disabled", name = "Old Owner", username = "old", disabled = true },
			{ id = "missing", name = "No Handle" },
		}, nil)
		assert.equal(1, #items)
		assert.equal("@ada.owner", items[1].insert_text)
		assert.equal("ada.owner Ada Owner", items[1].filter_text)
	end)
end)
