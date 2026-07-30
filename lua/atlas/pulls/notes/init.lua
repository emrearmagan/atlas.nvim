local storage = require("atlas.pulls.notes.storage")

local M = {}

M.types = { "issue", "suggestion", "note", "praise" }

---@alias AtlasNoteType "issue"|"suggestion"|"note"|"praise"

---@class AtlasNoteTarget
---@field ref string
---@field provider string
---@field host string
---@field repository string
---@field id string
---@field url string|nil
---@field repo_path string|nil

---@class AtlasNoteInput
---@field file_path string
---@field line integer
---@field body string
---@field type AtlasNoteType|nil
---@field head_sha string

---@class AtlasNote: AtlasNoteInput
---@field id string
---@field type AtlasNoteType
---@field created_at string
---@field updated_at string|nil

---@class AtlasNotePatch
---@field body string|nil
---@field type AtlasNoteType|nil

---@class AtlasNotesDocument
---@field target AtlasNoteTarget
---@field notes AtlasNote[]

---@param value any
---@return string
local function text(value)
	return vim.trim(tostring(value or ""))
end

---@param value table
---@return AtlasNoteTarget|nil, string|nil
local function normalize_target(value)
	if type(value) ~= "table" then
		return nil, "A pull request target is required"
	end
	local provider = text(value.provider):lower()
	local host = text(value.host):lower()
	local repository = text(value.repository):gsub("^/+", ""):gsub("/+$", ""):gsub("%.git$", "")
	local id = text(value.id)
	if provider == "" or host == "" or repository == "" or id == "" then
		return nil, "Invalid pull request target"
	end
	if provider ~= "gitlab" then
		repository = repository:lower()
	end
	local url = text(value.url)
	local repo_path = text(value.repo_path)
	return {
		ref = string.format("%s:%s/%s/pr/%s", provider, host, repository, id),
		provider = provider,
		host = host,
		repository = repository,
		id = id,
		url = url ~= "" and url or nil,
		repo_path = repo_path ~= "" and vim.fs.normalize(repo_path) or nil,
	},
		nil
end

---@param target AtlasNoteTarget
---@param current AtlasNoteTarget
---@return AtlasNoteTarget
local function merge_target(target, current)
	target.url = current.url or target.url
	target.repo_path = current.repo_path or target.repo_path
	return target
end

---@param value any
---@return string|nil, string|nil
local function normalize_file_path(value)
	local path = text(value):gsub("\\", "/"):gsub("^%./", "")
	if path == "" or path:sub(1, 1) == "/" or path:match("^%a:/") then
		return nil, "Note file paths must be relative to the repository"
	end
	for segment in path:gmatch("[^/]+") do
		if segment == ".." then
			return nil, "Note file paths cannot contain .."
		end
	end
	return path, nil
end

---@param value any
---@return AtlasNoteType|nil, string|nil
local function normalize_type(value)
	local note_type = text(value)
	if note_type == "" then
		note_type = "note"
	end
	note_type = note_type:lower()
	if not vim.tbl_contains(M.types, note_type) then
		return nil, "Note type must be issue, suggestion, note, or praise"
	end
	---@cast note_type AtlasNoteType
	return note_type, nil
end

---@param value table
---@return AtlasNote|nil, string|nil
local function normalize_note(value)
	if type(value) ~= "table" then
		return nil, "Note must be an object"
	end
	local file_path, path_error = normalize_file_path(value.file_path)
	if not file_path then
		return nil, path_error
	end
	local line = tonumber(value.line)
	if not line or line < 1 or line % 1 ~= 0 then
		return nil, "Line must be a positive integer"
	end
	if type(value.body) ~= "string" or text(value.body) == "" then
		return nil, "Note body cannot be empty"
	end
	local note_type, type_error = normalize_type(value.type)
	if not note_type then
		return nil, type_error
	end
	local head_sha = text(value.head_sha)
	if head_sha == "" then
		return nil, "A head commit is required"
	end
	local id = text(value.id)
	local created_at = text(value.created_at)
	local updated_at = text(value.updated_at)
	if id == "" or created_at == "" then
		return nil, "Stored note is missing its id or timestamp"
	end
	return {
		id = id,
		file_path = file_path,
		line = line,
		body = value.body,
		type = note_type,
		head_sha = head_sha,
		created_at = created_at,
		updated_at = updated_at ~= "" and updated_at or nil,
	},
		nil
end

---@return string
local function now()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---@param value any
---@param expected AtlasNoteTarget|nil
---@return AtlasNotesDocument|nil, string|nil
local function normalize_document(value, expected)
	if type(value) ~= "table" or type(value.notes) ~= "table" or not vim.islist(value.notes) then
		return nil, "Invalid notes document"
	end
	local target, target_error = normalize_target(value.target)
	if not target then
		return nil, target_error
	end
	if expected and target.ref ~= expected.ref then
		return nil, "Notes document belongs to another pull request"
	end
	local items = {}
	for _, value_note in ipairs(value.notes) do
		local note, note_error = normalize_note(value_note)
		if not note then
			return nil, note_error
		end
		table.insert(items, note)
	end
	return {
		target = expected and merge_target(target, expected) or target,
		notes = items,
	}, nil
end

---@param target AtlasNoteTarget
---@return AtlasNotesDocument|nil, string|nil
local function load_document(target)
	local value, read_error = storage.read(storage.path(target.ref))
	if read_error then
		return nil, read_error
	end
	if not value then
		return { target = target, notes = {} }, nil
	end
	return normalize_document(value, target)
end

---@param target AtlasNoteTarget
---@param mutate fun(document: AtlasNotesDocument): any, string|nil
---@return any, string|nil
local function change(target, mutate)
	local document, read_error = load_document(target)
	if not document then
		return nil, read_error
	end
	local result, mutation_error = mutate(document)
	if mutation_error then
		return nil, mutation_error
	end
	document.target = merge_target(document.target, target)
	local write_error = storage.write(storage.path(target.ref), document)
	if write_error then
		return nil, write_error
	end
	return result, nil
end

---@param value string
---@return AtlasNoteTarget|nil, string|nil
function M.resolve_target(value)
	value = text(value)
	local provider, host, repository, id = value:match("^([%w_-]+):([^/]+)/(.+)/pr/(%d+)$")
	if provider then
		return normalize_target({ provider = provider, host = host, repository = repository, id = id })
	end

	local url_host, path = value:match("^https?://([^/?#]+)([^?#]*)")
	if not url_host then
		return nil, "Expected a pull request URL or canonical reference"
	end
	local owner, repo
	owner, repo, id = path:match("^/([^/]+)/([^/]+)/pull/(%d+)/?$")
	if owner then
		provider, repository = "github", owner .. "/" .. repo
	else
		owner, repo, id = path:match("^/([^/]+)/([^/]+)/pull%-requests/(%d+)/?$")
		if owner then
			provider, repository = "bitbucket", owner .. "/" .. repo
		else
			repository, id = path:match("^/(.-)/%-/merge_requests/(%d+)/?$")
			provider = repository and "gitlab" or nil
		end
	end
	if not provider or not repository or not id then
		return nil, "Unsupported pull request URL"
	end
	return normalize_target({
		provider = provider,
		host = url_host,
		repository = repository,
		id = id,
		url = value,
	})
end

---@param pr PullRequest
---@param repo_path string|nil
---@return AtlasNoteTarget|nil, string|nil
function M.target_for_pull_request(pr, repo_path)
	local url = pr.link.html
	return normalize_target({
		provider = pr.provider,
		host = url:match("^https?://([^/?#]+)"),
		repository = pr.repo_full_name,
		id = pr.id,
		url = url,
		repo_path = repo_path,
	})
end

---@param target AtlasNoteTarget
---@return string
function M.target_label(target)
	return string.format("%s#%s", target.repository, target.id)
end

---@return AtlasNotesDocument[]|nil, string|nil
function M.documents()
	local documents = {}
	for _, path in ipairs(storage.files()) do
		local value, read_error = storage.read(path)
		if read_error then
			return nil, read_error
		end
		local document, document_error = normalize_document(value)
		if not document then
			return nil, document_error
		end
		table.insert(documents, document)
	end
	table.sort(documents, function(left, right)
		return left.target.ref < right.target.ref
	end)
	return documents, nil
end

---@param target AtlasNoteTarget
---@return AtlasNote[]|nil, string|nil
function M.list(target)
	local document, read_error = load_document(target)
	return document and document.notes or nil, read_error
end

---@param target AtlasNoteTarget
---@param input AtlasNoteInput
---@return AtlasNote|nil, string|nil
function M.add(target, input)
	return change(target, function(document)
		local timestamp = now()
		local note, note_error = normalize_note(vim.tbl_extend("force", input, {
			id = "note_" .. vim.fn.sha256(timestamp .. tostring(vim.uv.hrtime())):sub(1, 16),
			created_at = timestamp,
		}))
		if not note then
			return nil, note_error
		end
		table.insert(document.notes, note)
		return note, nil
	end)
end

---@param target AtlasNoteTarget
---@param id string
---@param patch AtlasNotePatch
---@return AtlasNote|nil, string|nil
function M.update(target, id, patch)
	return change(target, function(document)
		for index, note in ipairs(document.notes) do
			if note.id == id then
				local candidate = {
					id = note.id,
					file_path = note.file_path,
					line = note.line,
					body = patch.body or note.body,
					type = patch.type or note.type,
					head_sha = note.head_sha,
					created_at = note.created_at,
					updated_at = now(),
				}
				local updated, update_error = normalize_note(candidate)
				if not updated then
					return nil, update_error
				end
				document.notes[index] = updated
				return updated, nil
			end
		end
		return nil, "Note not found: " .. id
	end)
end

---@param target AtlasNoteTarget
---@param id string
---@return boolean, string|nil
function M.delete(target, id)
	local deleted, err = change(target, function(document)
		for index, note in ipairs(document.notes) do
			if note.id == id then
				table.remove(document.notes, index)
				return true, nil
			end
		end
		return nil, "Note not found: " .. id
	end)
	return deleted == true, err
end

return M
