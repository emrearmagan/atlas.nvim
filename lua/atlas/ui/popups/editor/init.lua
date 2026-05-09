local M = {}

local layout = require("atlas.ui.popups.editor.layout")
local renderer = require("atlas.ui.popups.editor.renderer")

M.open = layout.open
M.close = layout.close
M.render_meta = renderer.render_meta

return M
