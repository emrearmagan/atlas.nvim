-- The built-in ATLAS syntax kept coloring random words in our buffers because of the name.
-- Disable it here for all atlas.* panels so we don't have to do it individually.
if vim.bo.filetype:match("^atlas%.") then
	vim.cmd.syntax("clear")
end
