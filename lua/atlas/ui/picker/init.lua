local M = {}

local config = require("atlas.config")

---@alias AtlasPickerName "auto"|"default"|"snacks"|"fzf-lua"
---@alias AtlasPickerSize { width: number, height: number }

---@class AtlasPickerPreview
---@field lines string[]
---@field title string|nil
---@field highlights AtlasUIHighlight[]|nil

---@alias AtlasPickerChunk { [1]: string, [2]: string|nil }
---@alias AtlasPickerFormatItem fun(item: any): string, string|AtlasPickerChunk[]|nil
---@alias AtlasPickerPreviewItem fun(item: any, done: fun(preview: AtlasPickerPreview), width: integer): { cancel: fun() }|nil
---@alias AtlasPickerFetch fun(query: string, done: fun(items: any[]|nil, err: string|nil)): { cancel: fun() }|nil

---@class AtlasPickerRequest
---@field title string
---@field items any[]
---@field format_item AtlasPickerFormatItem
---@field key fun(item: any): string
---@field preview_item AtlasPickerPreviewItem|nil
---@field preview_wo table<string, any>|nil
---@field fetch AtlasPickerFetch|nil
---@field multi boolean
---@field selected any[]
---@field initial_index integer|nil
---@field size AtlasPickerSize
---@field fetch_on_open boolean|nil
---@field debounce_ms integer|nil
---@field on_done fun(value: any|any[])
---@field on_cancel (fun())|nil

local picker_modules = {
	default = "atlas.ui.picker.atlas",
	snacks = "atlas.ui.picker.snacks",
	["fzf-lua"] = "atlas.ui.picker.fzf_lua",
}

local sizes = {
	compact = { width = 0.6, height = 0.45 },
	preview = { width = 0.7, height = 0.7 },
}

---@param request AtlasPickerRequest
---@param item any
---@return string, AtlasPickerChunk[]
function M.format_item(request, item)
	local text, formatting = request.format_item(item)
	text = tostring(text or "")
	if type(formatting) == "table" then
		return text, formatting
	end
	return text, { { text, formatting } }
end

---@param win integer
---@return integer
function M.preview_width(win)
	return vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
end

---@param name string
local function load(name)
	local module = picker_modules[name]
	if not module then
		return nil
	end
	local ok, picker = pcall(require, module)
	return ok and picker or nil
end

local function current_picker()
	local name = config.options.ui.picker or "auto"
	if name ~= "auto" then
		return assert(load(name), string.format("Picker '%s' is not available", name))
	end
	return load("snacks") or load("fzf-lua") or load("default")
end

---@param request AtlasPickerRequest
local function open_backend(request)
	request.size = request.size or (request.preview_item and sizes.preview or sizes.compact)
	request.preview_wo = vim.tbl_extend("force", {
		wrap = true,
		linebreak = true,
		number = false,
		relativenumber = false,
		cursorline = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		list = false,
	}, request.preview_wo or {})
	current_picker().open(request)
end

---@param opts {
--- title: string,
--- items: any[],
--- format_item: AtlasPickerFormatItem|nil,
--- initial_index: integer|nil,
--- size: AtlasPickerSize|nil,
--- on_select: fun(item: any|nil),
---}
function M.select(opts)
	open_backend({
		title = opts.title,
		items = opts.items,
		format_item = opts.format_item or tostring,
		key = tostring,
		multi = false,
		selected = {},
		initial_index = opts.initial_index,
		size = opts.size,
		on_done = opts.on_select,
		on_cancel = function()
			opts.on_select(nil)
		end,
	})
end

---@param opts { title: string, items: any[], key: (fun(item: any): string), format_item: AtlasPickerFormatItem, preview_item: AtlasPickerPreviewItem, preview_wo: table<string, any>|nil, initial_index: integer|nil, size: AtlasPickerSize|nil, on_select: (fun(item: any|nil)) }
function M.select_with_preview(opts)
	open_backend({
		title = opts.title,
		items = opts.items,
		format_item = opts.format_item,
		key = opts.key,
		preview_item = opts.preview_item,
		preview_wo = opts.preview_wo,
		multi = false,
		selected = {},
		initial_index = opts.initial_index,
		size = opts.size,
		on_done = opts.on_select,
		on_cancel = function()
			opts.on_select(nil)
		end,
	})
end

---@param opts { title: string, items: any[], selected: any[], key: (fun(item: any): string), format_item: AtlasPickerFormatItem, preview_item: AtlasPickerPreviewItem|nil, preview_wo: table<string, any>|nil, size: AtlasPickerSize|nil, on_done: (fun(selected: any[])) }
function M.multi_select(opts)
	local available = {}
	for _, item in ipairs(opts.items) do
		available[opts.key(item)] = true
	end

	open_backend({
		title = opts.title,
		items = opts.items,
		format_item = opts.format_item,
		key = opts.key,
		preview_item = opts.preview_item,
		preview_wo = opts.preview_wo,
		multi = true,
		selected = opts.selected,
		size = opts.size,
		on_done = function(selected)
			local selected_keys = {}
			for _, item in ipairs(selected) do
				selected_keys[opts.key(item)] = true
			end
			for _, item in ipairs(opts.selected) do
				local key = opts.key(item)
				if not available[key] and not selected_keys[key] then
					table.insert(selected, item)
				end
			end
			opts.on_done(selected)
		end,
		on_cancel = function()
			opts.on_done(opts.selected)
		end,
	})
end

---@param opts {
--- title: string,
--- initial_items: any[]|nil,
--- key: (fun(item: any): string)|nil,
--- debounce_ms: integer|nil,
--- fetch_on_open: boolean|nil,
--- size: AtlasPickerSize|nil,
--- format_item: AtlasPickerFormatItem,
--- preview_item: AtlasPickerPreviewItem|nil,
--- preview_wo: table<string, any>|nil,
--- fetch: AtlasPickerFetch,
--- on_select: (fun(item: any)),
--- on_cancel: (fun())|nil,
---}
function M.search(opts)
	open_backend({
		title = opts.title,
		items = opts.initial_items or {},
		format_item = opts.format_item,
		key = opts.key or function(item)
			return tostring(item.id)
		end,
		preview_item = opts.preview_item,
		preview_wo = opts.preview_wo,
		fetch = opts.fetch,
		multi = false,
		selected = {},
		size = opts.size,
		fetch_on_open = opts.fetch_on_open,
		debounce_ms = opts.debounce_ms == nil and 250 or opts.debounce_ms,
		on_done = opts.on_select,
		on_cancel = opts.on_cancel,
	})
end

return M
