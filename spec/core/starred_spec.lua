local original = {
	fs = vim.fs,
	uv = vim.uv,
	stdpath = vim.fn.stdpath,
	filereadable = vim.fn.filereadable,
	readfile = vim.fn.readfile,
	writefile = vim.fn.writefile,
	delete = vim.fn.delete,
	mkdir = vim.fn.mkdir,
	encode = vim.json.encode,
	decode = vim.json.decode,
}

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = copy(item)
	end
	return result
end

local function refs(items)
	local result = {}
	for _, item in ipairs(items) do
		table.insert(result, item.ref)
	end
	return result
end

describe("core.starred", function()
	local starred
	local stored
	local pending
	local exists

	before_each(function()
		stored, pending, exists = nil, nil, false
		vim.fs = {
			joinpath = function(...)
				return table.concat({ ... }, "/")
			end,
			dirname = function(value)
				return value:match("^(.*)/")
			end,
		}
		vim.uv = {
			hrtime = function()
				return 1
			end,
			fs_rename = function()
				stored, exists = pending, true
				return true
			end,
		}
		vim.fn.stdpath = function()
			return "/atlas-starred-spec"
		end
		vim.fn.filereadable = function()
			return exists and 1 or 0
		end
		vim.fn.readfile = function()
			return { "json" }
		end
		vim.fn.writefile = function()
			return 0
		end
		vim.fn.delete = function()
			stored, exists = nil, false
			return 0
		end
		vim.fn.mkdir = function()
			return 1
		end
		vim.json.encode = function(value)
			pending = copy(value)
			return "json"
		end
		vim.json.decode = function()
			return copy(stored)
		end

		package.loaded["atlas.core.starred"] = nil
		starred = require("atlas.core.starred")
	end)

	after_each(function()
		vim.fs = original.fs
		vim.uv = original.uv
		vim.fn.stdpath = original.stdpath
		vim.fn.filereadable = original.filereadable
		vim.fn.readfile = original.readfile
		vim.fn.writefile = original.writefile
		vim.fn.delete = original.delete
		vim.fn.mkdir = original.mkdir
		vim.json.encode = original.encode
		vim.json.decode = original.decode
		package.loaded["atlas.core.starred"] = nil
	end)

	it("adds, toggles, and clears items", function()
		local pull = { id = 7, repo_full_name = "octo/repo", title = "Pull" }
		local repo = { id = "octo/repo", name = "repo" }

		local item = assert(starred.add(pull, "github", repo))
		assert.are.equal("github:pulls/octo/repo#7", item.ref)
		assert.are.same({ item }, assert(starred.list()))

		local is_starred = starred.toggle(pull, "github", repo)
		assert.is_false(is_starred)
		assert.are.same({}, assert(starred.list()))

		is_starred = starred.toggle(pull, "github", repo)
		assert.is_true(is_starred)
		assert.is_true(starred.clear_all())
		assert.are.same({}, assert(starred.list()))
	end)

	it("filters items by domain and provider", function()
		assert(starred.add({ key = "GH-1" }, "github"))
		assert(starred.add({ key = "JIRA-1" }, "jira"))
		assert(starred.add({ id = 7, repo_full_name = "octo/repo" }, "github"))

		assert.are.same({ "github:issues/GH-1", "jira:issues/JIRA-1" }, refs(assert(starred.list("issues"))))
		assert.are.same({ "github:issues/GH-1", "github:pulls/octo/repo#7" }, refs(assert(starred.list(nil, "github"))))
		assert.are.same({ "github:issues/GH-1" }, refs(assert(starred.list("issues", "github"))))
	end)
end)
