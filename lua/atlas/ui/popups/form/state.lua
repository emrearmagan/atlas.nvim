---@alias EditorPopupBufferName "title"|"meta"|"desc"

---@class EditorPopupLayout
---@field container_buf integer|nil
---@field container_win integer|nil
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil

---@class EditorPopupKeymap
---@field key string
---@field mode string|string[]|nil
---@field buffers EditorPopupBufferName[]
---@field action fun()
---@field desc string
---@field show_in_footer boolean|nil

---@class EditorPopupMetaSpan
---@field start_col integer
---@field end_col integer
---@field hl_group string

---@class EditorPopupMetaCell
---@field text string
---@field hl string|nil
---@field spans EditorPopupMetaSpan[]|nil

---@alias EditorPopupMetaRow (string|EditorPopupMetaCell)[]

---@class EditorPopupOpenOpts
---@field title string
---@field min_height integer
---@field meta_height integer
---@field title_winbar string
---@field desc_winbar string
---@field initial_title string
---@field initial_body string
---@field close fun()
---@field submit fun()
---@field keymaps EditorPopupKeymap[]|nil
---@field meta fun(): EditorPopupMetaRow[]

local M = {}

return M
