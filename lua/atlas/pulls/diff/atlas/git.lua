local M = {}

local core_git = require("atlas.core.git")

---@class AtlasNativeDiffRange: AtlasDiffSource
---@field head_revision string Immutable commit hash.

---@class AtlasNativeDiffData
---@field range AtlasNativeDiffRange
---@field files DiffFile[]
---@field document AtlasDiffDocument

---@class AtlasNativeDiffGitOperation
---@field cancelled boolean
---@field finished boolean
---@field handles { cancel: fun() }[]
---@field cancel fun()
---@field finish fun(self: AtlasNativeDiffGitOperation, result: any, err: string|nil)

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

---@param callback fun(result: any, err: string|nil)
---@return AtlasNativeDiffGitOperation
local function new_operation(callback)
	---@type AtlasNativeDiffGitOperation
	local op = {
		cancelled = false,
		finished = false,
		handles = {},
	}
	local function cancel_handles()
		for _, handle in ipairs(op.handles) do
			handle.cancel()
		end
		op.handles = {}
	end

	op.cancel = function()
		if op.cancelled or op.finished then
			return
		end
		op.cancelled = true
		cancel_handles()
	end

	---@param ... any
	function op:finish(...)
		if self.cancelled or self.finished then
			return
		end
		self.finished = true
		cancel_handles()
		callback(...)
	end

	return op
end

---@param op AtlasNativeDiffGitOperation
---@param args string[]
---@param opts vim.SystemOpts
---@param on_exit fun(res: vim.SystemCompleted)
local function run_git(op, args, opts, on_exit)
	if op.cancelled or op.finished then
		return
	end

	local ok, handle = pcall(core_git.run, args, opts, function(res)
		if not op.cancelled and not op.finished then
			on_exit(res)
		end
	end)
	if ok and handle then
		table.insert(op.handles, handle)
		return
	end

	vim.schedule(function()
		if not op.cancelled and not op.finished then
			op:finish(nil, ok and "Failed to start git" or tostring(handle))
		end
	end)
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

---@param op AtlasNativeDiffGitOperation
---@param root string
---@param base_revision string
---@param head_revision string
---@param on_done fun(range: AtlasNativeDiffRange)
local function resolve_range(op, root, base_revision, head_revision, on_done)
	root = tostring(root or "")
	base_revision = trim(base_revision)
	head_revision = trim(head_revision)

	if root == "" or base_revision == "" or head_revision == "" then
		vim.schedule(function()
			op:finish(nil, "Repository path, base revision, and head revision are required")
		end)
		return
	end

	run_git(
		op,
		{ "rev-parse", "--verify", "--end-of-options", head_revision .. "^{commit}" },
		{ cwd = root, text = true },
		function(head_res)
			local head_hash = trim(head_res.stdout)
			if head_res.code ~= 0 or head_hash == "" then
				op:finish(nil, command_error(head_res, "Failed to resolve head revision"))
				return
			end
			run_git(
				op,
				{ "merge-base", "--", base_revision, head_hash },
				{ cwd = root, text = true },
				function(merge_res)
					local merge_base = trim(merge_res.stdout)
					if merge_res.code ~= 0 or merge_base == "" then
						op:finish(nil, command_error(merge_res, "Failed to resolve merge base"))
						return
					end
					on_done({ root = root, base_revision = merge_base, head_revision = head_hash })
				end
			)
		end
	)
end

---@param op AtlasNativeDiffGitOperation
---@param range AtlasNativeDiffRange
---@param on_done fun(files: DiffFile[])
local function list_files(op, range, on_done)
	local root = tostring(range and range.root or "")
	local base = trim(range and range.base_revision)
	local head = trim(range and range.head_revision)
	if root == "" or base == "" or head == "" then
		vim.schedule(function()
			op:finish(nil, "A resolved diff range is required")
		end)
		return
	end

	local diff_range = base .. ".." .. head
	run_git(
		op,
		{ "diff", "--find-renames", "--name-status", "-z", diff_range, "--" },
		{ cwd = root, text = false },
		function(res)
			if res.code ~= 0 then
				op:finish(nil, command_error(res, "Failed to list changed files"))
				return
			end
			local files = parse_name_status(res.stdout or "")
			if #files == 0 then
				on_done(files)
				return
			end
			run_git(
				op,
				{ "diff", "--find-renames", "--numstat", "-z", diff_range, "--" },
				{ cwd = root, text = false },
				function(stats_res)
					if stats_res.code ~= 0 then
						op:finish(nil, command_error(stats_res, "Failed to load diff statistics"))
						return
					end
					apply_stats(files, parse_numstat(stats_res.stdout or ""))
					on_done(files)
				end
			)
		end
	)
end

-- Documents

---@param op AtlasNativeDiffGitOperation
---@param root string
---@param revision string
---@param path string
---@param on_done fun(content: string|nil, err: string|nil)
local function load_content(op, root, revision, path, on_done)
	if path == "" then
		vim.schedule(function()
			if not op.cancelled and not op.finished then
				on_done("", nil)
			end
		end)
		return
	end

	local object = revision .. ":" .. path
	run_git(op, { "cat-file", "blob", object }, { cwd = root, text = false }, function(res)
		if res.code == 0 then
			on_done(res.stdout or "", nil)
			return
		end
		local original_error = command_error(res, "Failed to load file content")
		run_git(
			op,
			{ "rev-parse", "--verify", "--end-of-options", object },
			{ cwd = root, text = true },
			function(object_res)
				local object_id = trim(object_res.stdout)
				if object_res.code ~= 0 or object_id == "" then
					on_done(nil, original_error)
					return
				end
				run_git(op, { "cat-file", "-t", object_id }, { cwd = root, text = true }, function(type_res)
					if type_res.code == 0 and trim(type_res.stdout) == "commit" then
						on_done("Subproject commit " .. object_id .. "\n", nil)
						return
					end
					on_done(nil, original_error)
				end)
			end
		)
	end)
end

---@param op AtlasNativeDiffGitOperation
---@param range AtlasNativeDiffRange
---@param file DiffFile
---@param on_done fun(document: AtlasDiffDocument)
local function load_document(op, range, file, on_done)
	local root = tostring(range and range.root or "")
	local base = trim(range and range.base_revision)
	local head = trim(range and range.head_revision)
	if root == "" or base == "" or head == "" then
		vim.schedule(function()
			op:finish(nil, "A resolved diff range is required")
		end)
		return
	end
	if file.path == "" then
		vim.schedule(function()
			op:finish(nil, "A changed file is required")
		end)
		return
	end

	local old_path = file.old_path or file.path
	local old_query = file.status == "added" and "" or old_path
	local new_query = file.status == "deleted" and "" or file.path
	local result = {}

	local function complete()
		if result.old == nil or result.new == nil then
			return
		end
		if result.error then
			op:finish(nil, result.error)
			return
		end

		local old_lines, old_binary = content_lines(result.old)
		local new_lines, new_binary = content_lines(result.new)
		local binary = old_binary or new_binary
		local hunks, hunk_error = diff_hunks(old_lines, new_lines, result.old, result.new, binary)
		if not hunks then
			op:finish(nil, hunk_error)
			return
		end
		on_done({
			status = file.status,
			old = { path = old_path, lines = old_lines },
			new = { path = file.path, lines = new_lines },
			changes = hunks,
			binary = binary,
		})
	end

	load_content(op, root, base, old_query, function(content, err)
		result.old = content or ""
		result.error = result.error or err
		complete()
	end)
	load_content(op, root, head, new_query, function(content, err)
		result.new = content or ""
		result.error = result.error or err
		complete()
	end)
end

---@param range AtlasNativeDiffRange
---@param file DiffFile
---@param on_done fun(document: AtlasDiffDocument|nil, err: string|nil)
---@return { cancel: fun() }
function M.document(range, file, on_done)
	local op = new_operation(on_done)
	load_document(op, range, file, function(document)
		op:finish(document, nil)
	end)
	return op
end

-- Initial diff data

---@param options { git_root: string, base_revision: string, head_revision: string, filter: (fun(files: DiffFile[]): DiffFile[])|nil }
---@param on_done fun(result: AtlasNativeDiffData|nil, err: string|nil)
---@return { cancel: fun() }
function M.load(options, on_done)
	local op = new_operation(on_done)
	resolve_range(op, options.git_root, options.base_revision, options.head_revision, function(range)
		list_files(op, range, function(files)
			if options.filter then
				local ok, filtered = pcall(options.filter, files)
				if not ok then
					op:finish(nil, "Unable to filter changed files: " .. tostring(filtered))
					return
				end
				files = filtered
			end
			if #files == 0 then
				op:finish(nil, "The range has no visible changed files")
				return
			end

			load_document(op, range, files[1], function(document)
				op:finish({ range = range, files = files, document = document }, nil)
			end)
		end)
	end)

	return op
end

return M
