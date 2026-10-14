local CLIENT = "atlas.providers.shortcut.client"
local MODULES = {
	CLIENT,
	"atlas.providers.shortcut.users",
	"atlas.issues.providers.shortcut.api.stories",
	"atlas.issues.providers.shortcut.api.comments",
	"atlas.issues.providers.shortcut.api.workflows",
}

describe("Shortcut backend workflows", function()
	local saved, calls, pending, cached, replies, errors, deferred, result, err
	local member = { id = "owner", name = "Ada Owner", mention_name = "ada.owner" }
	local story = {
		id = 123,
		name = "A Story",
		story_type = "feature",
		workflow_state_id = 10,
		owner_ids = { "owner" },
		app_url = "https://app.shortcut.com/acme/story/123/a-story",
	}
	local function done(value, error)
		result, err = value, error
	end

	before_each(function()
		saved = {}
		for _, name in ipairs(MODULES) do
			saved[name], package.loaded[name] = package.loaded[name], nil
		end
		calls, pending, cached, errors = {}, {}, {}, {}
		deferred, result, err = false, nil, nil
		replies = {
			["/member"] = member,
			["/members"] = { { id = member.id, profile = member } },
			["/workflows"] = { { id = 1, states = { { id = 10, name = "Todo" } } } },
			["/stories/123"] = story,
		}
		local client = {
			get_cache = function(key)
				return cached[key], cached[key] ~= nil
			end,
			set_cache = function(key, value)
				cached[key] = value
			end,
			clear_cache = function(prefix)
				for key in pairs(cached) do
					if key:sub(1, #prefix) == prefix then
						cached[key] = nil
					end
				end
			end,
			request = function(method, endpoint, data, callback)
				local call = { method = method, endpoint = endpoint, data = data }
				table.insert(calls, call)
				local complete = function()
					callback(not errors[endpoint] and (replies[endpoint] or {}) or nil, errors[endpoint])
				end
				if deferred then
					table.insert(pending, complete)
				else
					complete()
				end
				return {
					cancel = function()
						call.cancelled = true
					end,
				}
			end,
		}
		client.get_memory_cache, client.set_memory_cache = client.get_cache, client.set_cache
		package.loaded[CLIENT] = client
	end)

	after_each(function()
		for _, name in ipairs(MODULES) do
			package.loaded[name] = saved[name]
		end
	end)

	it("caches search pages, refreshes metadata and follows the server cursor", function()
		local stories = require("atlas.issues.providers.shortcut.api.stories")
		local endpoint = "/search/stories?query=owner%3Ame&page_size=25&detail=slim"
		replies[endpoint] = { data = { story }, total = 2000, next = "/api/v3/search/stories?next=stable" }
		replies["/search/stories?next=stable"] = { data = {}, total = 2000 }
		stories.search("owner:me", { pagelen = 25 }, done)
		assert.is_nil(err)
		assert.equal(40, result.total_pages)
		local count = #calls
		stories.search("owner:me", { pagelen = 25 }, done)
		assert.equal(count, #calls)
		assert.equal("owner:me", result.query)
		replies["/members"] = { { id = "owner", profile = { name = "Renamed Owner" } } }
		replies["/workflows"][1].states[1].name = "Ready"
		stories.search("owner:me", { pagelen = 25, force_refresh = true }, done)
		assert.equal("Renamed Owner", result.items[1].assignee.name)
		assert.equal("Ready", result.items[1].status)
		stories.search("owner:me", { pagelen = 25, cursor = result.next_cursor }, done)
		assert.equal("/search/stories?next=stable", calls[#calls].endpoint)
		assert.same({}, result.items)
		assert.is_nil(result.next_cursor)
	end)

	it("keeps failed searches editable", function()
		errors["/members"] = "HTTP 401"
		require("atlas.issues.providers.shortcut.api.stories").search("owner:me", {}, done)
		assert.equal("HTTP 401", err)
		assert.equal("owner:me", result.query)
		assert.same({}, result.items)
	end)

	it("fetches batch metadata once, preserves order and refreshes shared Story caches", function()
		local stories = require("atlas.issues.providers.shortcut.api.stories")
		replies["/stories/124"] = vim.tbl_extend("force", {}, story, { id = 124, name = "Second Story" })
		local refs = { { key = "124" }, { key = "123" } }
		deferred = true
		stories.fetch_by_refs(refs, {}, done)
		for index = #pending, 1, -1 do
			pending[index]()
		end
		assert.is_nil(err)
		assert.equal("124", result[1].key)
		assert.equal("123", result[2].key)
		assert.equal("Todo", result[1].status)
		assert.equal(4, #calls)
		deferred = false
		stories.get(123, {}, done)
		assert.equal("A Story", result.title)
		stories.fetch_by_refs(refs, {}, done)
		assert.equal(4, #calls)
		replies["/stories/123"] = vim.tbl_extend("force", {}, story, { name = "Changed Story" })
		replies["/members"] = { { id = "owner", profile = { name = "Renamed Owner" } } }
		stories.fetch_by_refs(refs, { force_refresh = true }, done)
		assert.equal(8, #calls)
		assert.equal("Changed Story", result[2].title)
		assert.equal("Renamed Owner", result[1].assignee.name)
	end)

	it("rejects foreign workspaces even in cache and keeps successful batch results", function()
		local stories = require("atlas.issues.providers.shortcut.api.stories")
		stories.get(123, { workspace = "acme" }, done)
		assert.is_nil(err)
		assert.equal("A Story", result.title)
		stories.get(123, { workspace = "other" }, done)
		assert.is_nil(result)
		assert.matches("does not belong to workspace other", err)
		errors["/stories/999"] = "HTTP 404"
		stories.fetch_by_refs({
			{ key = "123", workspace = "acme" },
			{ key = "999" },
			{ key = "123", workspace = "other" },
		}, {}, done)
		assert.equal(1, #result)
		assert.equal("123", result[1].key)
		assert.matches("#999: HTTP 404", err)
		assert.matches("#123: Shortcut Story does not belong", err)
	end)

	it("creates shared comment replies and invalidates Story and search caches", function()
		replies["/stories/123/comments"] = { id = 456, text = "A reply", author_id = "owner", parent_id = 100 }
		cached["story:123"], cached["search:query"] = story, { items = { story } }
		require("atlas.issues.providers.shortcut.api.comments").add_comment(
			story,
			"A reply",
			{ parent = { id = "100", body = "", created_at = "" } },
			done
		)
		assert.is_nil(err)
		assert.equal("POST", calls[#calls].method)
		assert.same({ text = "A reply", parent_id = 100 }, calls[#calls].data)
		assert.equal("owner", result.author.id)
		assert.equal("ada.owner", result.author.username)
		assert.equal(100, result.parent_id)
		assert.is_nil(cached["story:123"])
		assert.is_nil(cached["search:query"])
	end)

	it("cancels metadata requests without starting a search or delivering late results", function()
		deferred = true
		local scope = require("atlas.issues.providers.shortcut.api.stories").search("owner:me", {}, done)
		scope.cancel()
		for _, complete in ipairs(pending) do
			complete()
		end
		assert.equal(2, #calls)
		assert.is_true(calls[1].cancelled)
		assert.is_true(calls[2].cancelled)
		assert.is_nil(result)
	end)
end)
