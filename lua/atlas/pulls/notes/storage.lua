local M = {}

---@return string
function M.root()
	local configured = vim.trim(tostring(vim.env.ATLAS_NOTES_DIR or ""))
	return configured ~= "" and vim.fs.normalize(configured)
		or vim.fs.joinpath(vim.fn.stdpath("data"), "atlas", "notes")
end

---@param target_ref string
---@return string
function M.path(target_ref)
	return vim.fs.joinpath(M.root(), vim.fn.sha256(target_ref) .. ".json")
end

---@param path string
---@return table|nil, string|nil
function M.read(path)
	if vim.fn.filereadable(path) == 0 then
		return nil, nil
	end
	local ok, value = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	end)
	if not ok then
		return nil, "Unable to read notes: " .. path
	end
	return value, nil
end

---@param path string
---@param document AtlasNotesDocument
---@return string|nil
function M.write(path, document)
	if #document.notes == 0 then
		if vim.fn.delete(path) ~= 0 then
			return "Unable to delete notes: " .. path
		end
		return nil
	end
	local directory = vim.fs.dirname(path)
	if vim.fn.mkdir(directory, "p") == 0 and vim.fn.isdirectory(directory) == 0 then
		return "Unable to create notes directory"
	end
	local ok, encoded = pcall(vim.json.encode, document, { indent = "  " })
	if not ok then
		return "Unable to encode notes"
	end
	local temp = path .. ".tmp." .. tostring(vim.uv.hrtime())
	if vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), temp) ~= 0 then
		return "Unable to write notes"
	end
	local renamed, err = vim.uv.fs_rename(temp, path)
	if not renamed then
		vim.fn.delete(temp)
		return "Unable to save notes: " .. tostring(err)
	end
	return nil
end

---@return string[]
function M.files()
	return vim.fn.globpath(M.root(), "*.json", false, true)
end

return M
