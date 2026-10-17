local file = require("atlas.pulls.notes.file")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local storage = require("atlas.core.storage")

local M = {}

M.types = { "issue", "suggestion", "note", "praise" }

---@alias AtlasNoteType "issue"|"suggestion"|"note"|"praise"

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
---@field resolved boolean
---@field context AtlasNoteContext|nil
---@field created_at string
---@field updated_at string|nil

---@class AtlasNotePatch
---@field body string|nil
---@field type AtlasNoteType|nil
---@field resolved boolean|nil

---@class AtlasNotesDocument
---@field target AtlasStorageTarget
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
		resolved = value.resolved == true,
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
---@param expected AtlasStorageTarget|nil
---@return AtlasNotesDocument|nil, string|nil
local function normalize_document(value, expected)
	if type(value) ~= "table" or type(value.notes) ~= "table" or not vim.islist(value.notes) then
		return nil, "Invalid notes document"
	end
	local target, target_error = storage.target(value.target)
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
		target = target,
		notes = items,
	}, nil
end

---@param target AtlasStorageTarget
---@return AtlasNotesDocument|nil, string|nil
local function load_document(target)
	local value, read_error = file.read(file.path(target))
	if read_error then
		return nil, read_error
	end
	if not value then
		return { target = target, notes = {} }, nil
	end
	return normalize_document(value, target)
end

---@param target AtlasStorageTarget
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
	local write_error = file.write(file.path(target), document)
	if write_error then
		return nil, write_error
	end
	return result, nil
end

---@param value string
---@return AtlasStorageTarget|nil, string|nil
function M.resolve_target(value)
	local parsed = storage.parse(value)
	if parsed then
		return parsed
	end

	local target, err = providers.resolve(value)
	if not target or target.entity ~= "pr" then
		return nil, err or "Expected a pull request URL or canonical reference"
	end
	return storage.target({ host = target.host, repository = target.repo_full_name, id = target.id })
end

---@param target AtlasStorageTarget
---@return string
function M.target_label(target)
	return string.format("%s#%s", target.repository, target.id)
end

---@return AtlasNotesDocument[]|nil, string|nil
function M.documents()
	local documents = {}
	for _, path in ipairs(file.paths()) do
		local value, read_error = file.read(path)
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

---@param arglead string
---@param args string[]|nil
---@return string[]
function M.complete(arglead, args)
	if args and #args > 1 then
		return {}
	end
	local options = {}
	for _, document in ipairs(M.documents() or {}) do
		local ref = document.target.ref
		if ref:find(arglead, 1, true) == 1 then
			options[#options + 1] = ref
		end
	end
	return options
end

---@param target AtlasStorageTarget
---@return AtlasNote[]|nil, string|nil
function M.list(target)
	local document, read_error = load_document(target)
	return document and document.notes or nil, read_error
end

---@param pr PullRequest
---@return { target: AtlasStorageTarget, items: AtlasNote[] }|nil, string|nil
function M.for_pull_request(pr)
	local target, target_error = storage.target_for_pull_request(pr)
	if not target then
		return nil, target_error
	end
	local items, read_error = M.list(target)
	if not items then
		return nil, read_error
	end
	return { target = target, items = items }, nil
end

---@param target AtlasStorageTarget
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

---@param target AtlasStorageTarget
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
					resolved = note.resolved,
					context = note.context,
					created_at = note.created_at,
					updated_at = now(),
				}
				if patch.resolved ~= nil then
					candidate.resolved = patch.resolved
				end
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

---@param target AtlasStorageTarget
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

---@param target AtlasStorageTarget
---@return boolean, string|nil
function M.clear(target)
	local err = file.delete(file.path(target))
	return err == nil, err
end

---@param pr PullRequest
function M.clear_for_pull_request(pr)
	if (require("atlas.config").options.pulls or {}).delete_notes ~= true then
		return
	end
	local target, target_err = storage.target_for_pull_request(pr)
	if not target then
		notify.warn(target_err or "Unable to find notes", { vim_notify = true })
		return
	end
	local ok, err = M.clear(target)
	if not ok then
		notify.warn(err or "Unable to delete notes", { vim_notify = true })
		return
	end
	local ui = package.loaded["atlas.pulls.notes.ui"]
	if ui then
		ui.refresh()
	end
end

---@return boolean, string|nil
function M.clear_all()
	for _, path in ipairs(file.paths()) do
		local err = file.delete(path)
		if err then
			return false, err
		end
	end
	return true, nil
end

return M
