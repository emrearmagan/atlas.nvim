---@alias AtlasFormBufferName "editor"|"context"

---@class AtlasFormLayout
---@field tab integer|nil
---@field source_tab integer|nil
---@field source_win integer|nil
---@field editor_buf integer|nil
---@field editor_win integer|nil
---@field context_buf integer|nil
---@field context_win integer|nil
---@field footer_buf integer|nil
---@field footer_win integer|nil
---@field title_label string|nil
---@field body_label string|nil
---@field meta_height integer|nil
---@field placeholder_buf integer|nil
---@field augroup integer|nil
---@field closing boolean|nil

---@class AtlasFormKeymap
---@field key string|string[]
---@field mode string|string[]|nil
---@field buffers AtlasFormBufferName[]
---@field action fun()
---@field desc string

---@class AtlasFormMetaSpan
---@field start_col integer
---@field end_col integer
---@field hl_group string

---@class AtlasFormMetaCell
---@field text string
---@field hl string|nil
---@field spans AtlasFormMetaSpan[]|nil

---@alias AtlasFormMetaRow (string|AtlasFormMetaCell)[]

---@class AtlasFormOpenOpts
---@field title_label string
---@field body_label string
---@field context_title string|nil
---@field context (fun(): string[])|nil
---@field initial_title string
---@field initial_body string
---@field close fun()
---@field submit fun()
---@field keymaps AtlasFormKeymap[]|nil
---@field meta fun(): AtlasFormMetaRow[]

local M = {}

return M
