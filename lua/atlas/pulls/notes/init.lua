local notify = require("atlas.core.notify")
local resolver = require("atlas.providers.resolve")
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

---@class AtlasNoteContext
---@field start_line integer
---@field lines string[]

---@class AtlasNoteInput
---@field file_path string
---@field line integer
---@field body string
---@field type AtlasNoteType|nil
---@field context AtlasNoteContext|nil

---@class AtlasNote
---@field id string
---@field file_path string
---@field line integer
---@field body string
---@field type AtlasNoteType
---@field context AtlasNoteContext|nil
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

---@param note AtlasNote
---@param line string|nil
---@return boolean
function M.is_outdated(note, line)
	if not note.context then
		return true
	end
	local anchor = note.context.lines[note.line - note.context.start_line + 1]
	return anchor ~= line
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
	return {
		ref = string.format("%s:%s/%s/pr/%s", provider, host, repository, id),
		provider = provider,
		host = host,
		repository = repository,
		id = id,
		url = url ~= "" and url or nil,
	},
		nil
end

---@param target AtlasNoteTarget
---@param current AtlasNoteTarget
---@return AtlasNoteTarget
local function merge_target(target, current)
	target.url = current.url or target.url
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
	local context = value.context
	if context ~= nil then
		if type(context) ~= "table" then
			return nil, "Invalid note context"
		end
		local start_line = tonumber(context.start_line)
		local lines = context.lines
		if not start_line or type(lines) ~= "table" or type(lines[line - start_line + 1]) ~= "string" then
			return nil, "Invalid note context"
		end
		context = { start_line = start_line, lines = lines }
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
		context = context,
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

	local target, resolve_error = resolver.resolve(value)
	if not target then
		return nil, resolve_error
	end
	if target.domain ~= "pulls" or target.entity ~= "pr" then
		return nil, "Expected a pull request URL or canonical reference"
	end
	local ref = resolver.pull_request_ref(target)
	return normalize_target({
		provider = target.provider,
		host = target.host,
		repository = ref.repo_full_name,
		id = ref.id,
		url = target.url,
	})
end

---@param pr PullRequest
---@return AtlasNoteTarget|nil, string|nil
function M.target_for_pull_request(pr)
	local url = pr.link.html
	local parsed = resolver.parse_url(url)
	return normalize_target({
		provider = pr.provider,
		host = parsed and parsed.host or nil,
		repository = pr.repo_full_name,
		id = pr.id,
		url = url,
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
					context = note.context,
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

---@param target AtlasNoteTarget
---@return boolean, string|nil
function M.clear(target)
	local path = storage.path(target.ref)
	if vim.fn.filereadable(path) == 0 then
		return true, nil
	end
	if vim.fn.delete(path) ~= 0 then
		return false, "Unable to delete notes: " .. path
	end
	return true, nil
end

---@param pr PullRequest
function M.clear_for_pull_request(pr)
	if (require("atlas.config").options.pulls or {}).delete_notes ~= true then
		return
	end
	local target, target_err = M.target_for_pull_request(pr)
	if not target then
		notify.warn(target_err or "Unable to find local notes", { vim_notify = true })
		return
	end
	local ok, err = M.clear(target)
	if not ok then
		notify.warn(err or "Unable to delete local notes", { vim_notify = true })
		return
	end
	local ui = package.loaded["atlas.pulls.notes.ui"]
	if ui then
		ui.refresh()
	end
end

---@return boolean, string|nil
function M.clear_all()
	for _, path in ipairs(storage.files()) do
		if vim.fn.delete(path) ~= 0 then
			return false, "Unable to delete notes: " .. path
		end
	end
	return true, nil
end

return M
