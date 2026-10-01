local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")

local M = {}

local statuses = {
	A = "added",
	D = "deleted",
	M = "modified",
	R = "renamed",
	C = "copied",
	T = "type_changed",
}

local function run(root, args, on_done)
	return git.run(args, { cwd = root, text = false }, function(result)
		if result.code ~= 0 then
			on_done(nil, vim.trim(result.stderr))
			return
		end

		on_done(result.stdout, nil)
	end)
end

---@param root string
---@param revision string
---@param path string
---@param on_done fun(content: string|nil, err: string|nil)
---@return { cancel: fun() }
function M.read(root, revision, path, on_done)
	-- TODO: Submodules point to commits, not file contents. Show their hashes instead.
	return run(root, { "cat-file", "blob", revision .. ":" .. path }, on_done)
end

---@param source { root: string, base_revision: string, head_revision: string }
---@param on_done fun(result: { base_revision: string, files: AtlasDiffV2File[] }|nil, err: string|nil)
---@return { cancel: fun() }
function M.load(source, on_done)
	local requests = request_scope.new()

	requests.run(function(done)
		return run(source.root, { "merge-base", source.base_revision, source.head_revision }, done)
	end, function(output, err)
		if not output then
			on_done(nil, err)
			return
		end

		local merge_base = vim.trim(output)
		local function diff(format, done)
			return run(source.root, {
				"diff",
				format,
				"-z",
				"--find-renames",
				"--no-color",
				"--no-ext-diff",
				"--no-textconv",
				merge_base,
				source.head_revision,
				"--",
			}, done)
		end

		requests.all({
			files = function(done)
				return diff("--name-status", done)
			end,
			stats = function(done)
				return diff("--numstat", done)
			end,
		}, function(outputs, errors)
			local diff_err = errors.files or errors.stats
			if diff_err then
				on_done(nil, diff_err)
				return
			end

			-- Paths can contain tabs or newlines, so Git separates them with NULs.
			local status_fields = vim.split(outputs.files, "\0", { plain = true, trimempty = true })
			---@type AtlasDiffV2File[]
			local files = {}
			---@type table<string, AtlasDiffV2File>
			local files_by_path = {}
			local index = 1

			while index <= #status_fields do
				local status = status_fields[index]:sub(1, 1)
				local path = status_fields[index + 1]
				local old_path
				index = index + 2

				if status == "R" or status == "C" then
					old_path = path
					path = status_fields[index]
					index = index + 1
				end

				local file = {
					path = path,
					old_path = old_path,
					status = statuses[status],
					binary = false,
				}
				files[#files + 1] = file
				files_by_path[path] = file
			end

			local stat_fields = vim.split(outputs.stats, "\0", { plain = true, trimempty = true })
			index = 1

			while index <= #stat_fields do
				local additions, deletions, path = stat_fields[index]:match("^([^\t]+)\t([^\t]+)\t(.*)$")
				index = index + 1

				-- Renames put the old and new paths in the next two fields.
				if path == "" then
					path = stat_fields[index + 1]
					index = index + 2
				end

				local file = files_by_path[path]
				file.additions = tonumber(additions)
				file.deletions = tonumber(deletions)
				file.binary = additions == "-"
			end

			on_done({ base_revision = merge_base, files = files }, nil)
		end)
	end)

	return { cancel = requests.cancel }
end

return M
