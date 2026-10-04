local M = {}

local core_git = require("atlas.core.git")
local requests = require("atlas.core.requests")

---@class AtlasNativeDiffRange: AtlasDiffSource
---@field head_revision string Immutable commit hash.

---@class AtlasNativeDiffData
---@field range AtlasNativeDiffRange
---@field files DiffFile[]
---@field document AtlasDiffDocument

-- Git requests

---@param value string|nil
---@return string
local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param res vim.SystemCompleted
---@param fallback string
---@return string
local function command_error(res, fallback)
	local message = trim(res.stderr)
	if message == "" then
		message = string.format("%s (exit code %d)", fallback, res.code)
	end
	return message
end

-- Changed files

-- Git uses NUL separators because paths may contain tabs or newlines.
---@param output string
---@return string[]
local function split_nul(output)
	return vim.split(output, "\0", { plain = true, trimempty = true })
end

local FILE_STATUSES = {
	A = "added",
	M = "modified",
	D = "deleted",
	R = "renamed",
	T = "type_changed",
}

---@param code string
---@return DiffFileStatus
local function file_status(code)
	return FILE_STATUSES[code:sub(1, 1)] or "unknown"
end

---@param output string
---@return DiffFile[]
local function parse_name_status(output)
	local fields = split_nul(output)
	local files = {}
	local index = 1
	while index <= #fields do
		local code = fields[index]
		local kind = code:sub(1, 1)
		if kind == "R" then
			local old_path = fields[index + 1]
			local path = fields[index + 2]
			if old_path and path then
				table.insert(files, {
					status = file_status(code),
					old_path = old_path,
					path = path,
					hunks = {},
				})
			end
			index = index + 3
		else
			local path = fields[index + 1]
			if path then
				table.insert(files, {
					status = file_status(code),
					path = path,
					hunks = {},
				})
			end
			index = index + 2
		end
	end
	return files
end

---@param output string
---@return table<string, { additions: integer|nil, deletions: integer|nil }>
local function parse_numstat(output)
	local fields = split_nul(output)
	local stats = {}
	local index = 1
	while index <= #fields do
		local additions, deletions, path = fields[index]:match("^([^\t]*)\t([^\t]*)\t(.*)$")
		index = index + 1
		if not additions then
			break
		end
		if path == "" then
			local new_path = fields[index + 1]
			if not fields[index] or not new_path then
				break
			end
			path = new_path
			index = index + 2
		end
		stats[path] = {
			additions = tonumber(additions),
			deletions = tonumber(deletions),
		}
	end
	return stats
end

---@param files DiffFile[]
---@param stats table<string, { additions: integer|nil, deletions: integer|nil }>
local function apply_stats(files, stats)
	for _, file in ipairs(files) do
		local stat = stats[file.path]
		if stat then
			file.additions = stat.additions
			file.deletions = stat.deletions
		end
	end
end

---@param content string
---@return string[], boolean
local function content_lines(content)
	if content:find("\0", 1, true) then
		return { "Binary file" }, true
	end
	content = content:gsub("\r\n", "\n")
	local lines = vim.split(content, "\n", { plain = true })
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines, false
end

---@param old_lines string[]
---@param new_lines string[]
---@param old_content string
---@param new_content string
---@param binary boolean
---@return DiffHunk[]|nil, string|nil
local function diff_hunks(old_lines, new_lines, old_content, new_content, binary)
	if binary then
		return {}, nil
	end
	local ok, hunks = pcall(vim.diff, old_content, new_content, {
		algorithm = "histogram",
		result_type = "indices",
	})
	if not ok then
		return nil, "Unable to calculate diff: " .. tostring(hunks)
	end
	local result = {}
	for _, indices in ipairs(hunks) do
		local old_start, old_count, new_start, new_count = unpack(indices)
		local lines = {}
		for line = old_start, old_start + old_count - 1 do
			local content = old_lines[line] or ""
			table.insert(lines, {
				kind = "remove",
				text = "-" .. content,
				content = content,
				old_line = line,
				new_line = nil,
			})
		end
		for line = new_start, new_start + new_count - 1 do
			local content = new_lines[line] or ""
			table.insert(lines, {
				kind = "add",
				text = "+" .. content,
				content = content,
				old_line = nil,
				new_line = line,
			})
		end
		table.insert(result, {
			header = string.format("@@ -%d,%d +%d,%d @@", old_start, old_count, new_start, new_count),
			context = "",
			old_start = old_start,
			old_count = old_count,
			new_start = new_start,
			new_count = new_count,
			additions = new_count,
			deletions = old_count,
			lines = lines,
		})
	end
	return result, nil
end

-- Range and files

---@param root string
---@param base_revision string
---@param head_revision string
---@param on_done fun(range: AtlasNativeDiffRange|nil, err: string|nil)
---@return AtlasRequestScope
local function resolve_range(root, base_revision, head_revision, on_done)
	local scope = requests.new()
	root = tostring(root or "")
	base_revision = trim(base_revision)
	head_revision = trim(head_revision)

	if root == "" or base_revision == "" or head_revision == "" then
		scope.run(function(done)
			vim.schedule(function()
				done(nil, "Repository path, base revision, and head revision are required")
			end)
		end, on_done)
		return scope
	end

	scope.run(function(done)
		return core_git.run(
			{ "rev-parse", "--verify", "--end-of-options", head_revision .. "^{commit}" },
			{ cwd = root, text = true },
			done
		)
	end, function(head_res)
		local head_hash = trim(head_res.stdout)
		if head_res.code ~= 0 or head_hash == "" then
			on_done(nil, command_error(head_res, "Failed to resolve head revision"))
			return
		end
		scope.run(function(done)
			return core_git.run({ "merge-base", "--", base_revision, head_hash }, { cwd = root, text = true }, done)
		end, function(merge_res)
			local merge_base = trim(merge_res.stdout)
			if merge_res.code ~= 0 or merge_base == "" then
				on_done(nil, command_error(merge_res, "Failed to resolve merge base"))
				return
			end
			on_done({ root = root, base_revision = merge_base, head_revision = head_hash }, nil)
		end)
	end)
	return scope
end

---@param range AtlasNativeDiffRange
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return AtlasRequestScope
local function list_files(range, on_done)
	local scope = requests.new()
	local diff_range = range.base_revision .. ".." .. range.head_revision
	scope.run(function(done)
		return core_git.run(
			{ "diff", "--find-renames", "--name-status", "-z", diff_range, "--" },
			{ cwd = range.root, text = false },
			done
		)
	end, function(res)
		if res.code ~= 0 then
			on_done(nil, command_error(res, "Failed to list changed files"))
			return
		end
		local files = parse_name_status(res.stdout or "")
		if #files == 0 then
			on_done(files, nil)
			return
		end
		scope.run(function(done)
			return core_git.run(
				{ "diff", "--find-renames", "--numstat", "-z", diff_range, "--" },
				{ cwd = range.root, text = false },
				done
			)
		end, function(stats_res)
			if stats_res.code ~= 0 then
				on_done(nil, command_error(stats_res, "Failed to load diff statistics"))
				return
			end
			apply_stats(files, parse_numstat(stats_res.stdout or ""))
			on_done(files, nil)
		end)
	end)
	return scope
end

-- Documents

---@param root string
---@param revision string
---@param path string
---@param on_done fun(content: string|nil, err: string|nil)
---@return AtlasRequestScope|nil
local function load_content(root, revision, path, on_done)
	if path == "" then
		on_done("", nil)
		return
	end

	local scope = requests.new()
	local object = revision .. ":" .. path
	scope.run(function(done)
		return core_git.run({ "cat-file", "blob", object }, { cwd = root, text = false }, done)
	end, function(res)
		if res.code == 0 then
			on_done(res.stdout or "", nil)
			return
		end
		local original_error = command_error(res, "Failed to load file content")
		scope.run(function(done)
			return core_git.run(
				{ "rev-parse", "--verify", "--end-of-options", object },
				{ cwd = root, text = true },
				done
			)
		end, function(object_res)
			local object_id = trim(object_res.stdout)
			if object_res.code ~= 0 or object_id == "" then
				on_done(nil, original_error)
				return
			end
			scope.run(function(done)
				return core_git.run({ "cat-file", "-t", object_id }, { cwd = root, text = true }, done)
			end, function(type_res)
				if type_res.code == 0 and trim(type_res.stdout) == "commit" then
					on_done("Subproject commit " .. object_id .. "\n", nil)
					return
				end
				on_done(nil, original_error)
			end)
		end)
	end)
	return scope
end

---@param range AtlasNativeDiffRange
---@param file DiffFile
---@param on_done fun(document: AtlasDiffDocument|nil, err: string|nil)
---@return AtlasRequestScope
function M.document(range, file, on_done)
	local scope = requests.new()
	local root = tostring(range and range.root or "")
	local base = trim(range and range.base_revision)
	local head = trim(range and range.head_revision)
	local validation_err
	if root == "" or base == "" or head == "" then
		validation_err = "A resolved diff range is required"
	elseif file.path == "" then
		validation_err = "A changed file is required"
	end
	if validation_err then
		scope.run(function(done)
			vim.schedule(function()
				done(nil, validation_err)
			end)
		end, on_done)
		return scope
	end

	local old_path = file.old_path or file.path
	local old_query = file.status == "added" and "" or old_path
	local new_query = file.status == "deleted" and "" or file.path
	scope.all({
		old = function(done)
			return load_content(root, base, old_query, done)
		end,
		new = function(done)
			return load_content(root, head, new_query, done)
		end,
	}, function(contents, errors)
		local err = errors.old or errors.new
		if err then
			on_done(nil, err)
			return
		end

		local old_lines, old_binary = content_lines(contents.old)
		local new_lines, new_binary = content_lines(contents.new)
		local binary = old_binary or new_binary
		local hunks, hunk_error = diff_hunks(old_lines, new_lines, contents.old, contents.new, binary)
		if not hunks then
			on_done(nil, hunk_error)
			return
		end
		on_done({
			status = file.status,
			old = { path = old_path, lines = old_lines },
			new = { path = file.path, lines = new_lines },
			changes = hunks,
			binary = binary,
		}, nil)
	end)
	return scope
end

-- Initial diff data

---@param options { git_root: string, base_revision: string, head_revision: string, filter: (fun(files: DiffFile[]): DiffFile[])|nil }
---@param on_done fun(result: AtlasNativeDiffData|nil, err: string|nil)
---@return AtlasRequestScope
function M.load(options, on_done)
	local scope = requests.new()
	scope.run(function(done)
		return resolve_range(options.git_root, options.base_revision, options.head_revision, done)
	end, function(range, range_err)
		if not range then
			on_done(nil, range_err)
			return
		end
		scope.run(function(done)
			return list_files(range, done)
		end, function(files, files_err)
			if not files then
				on_done(nil, files_err)
				return
			end
			if options.filter then
				local ok, filtered = pcall(options.filter, files)
				if not ok then
					on_done(nil, "Unable to filter changed files: " .. tostring(filtered))
					return
				end
				files = filtered
			end
			if #files == 0 then
				on_done(nil, "The range has no visible changed files")
				return
			end

			scope.run(function(done)
				return M.document(range, files[1], done)
			end, function(document, err)
				if not document then
					on_done(nil, err)
					return
				end
				on_done({ range = range, files = files, document = document }, nil)
			end)
		end)
	end)

	return scope
end

return M
