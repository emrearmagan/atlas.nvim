local M = {}

local config = require("atlas.config")

---@alias AtlasPickerName "auto"|"default"|"snacks"|"fzf-lua"

---@class AtlasPickerPreview
---@field lines string[]
---@field title string|nil

---@alias AtlasPickerFormatItem fun(item: any): string, string|nil
---@alias AtlasPickerPreviewItem fun(item: any, done: fun(preview: AtlasPickerPreview)): { cancel: fun() }|nil
---@alias AtlasPickerFetch fun(query: string, done: fun(items: any[]|nil, err: string|nil)): { cancel: fun() }|nil

---@class AtlasPickerRequest
---@field title string
---@field items any[]
---@field format_item AtlasPickerFormatItem
---@field key fun(item: any): string
---@field preview_item AtlasPickerPreviewItem|nil
---@field fetch AtlasPickerFetch|nil
---@field multi boolean
---@field selected any[]
---@field initial_index integer|nil
---@field fetch_on_open boolean|nil
---@field debounce_ms integer|nil
---@field on_done fun(value: any|any[])
---@field on_cancel (fun())|nil

local picker_modules = {
	default = "atlas.picker.atlas",
	snacks = "atlas.picker.snacks",
	["fzf-lua"] = "atlas.picker.fzf_lua",
}

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
	current_picker().open(request)
end

---@param opts {
--- title: string,
--- items: any[],
--- kind: string|nil,
--- format_item: (fun(item: any): string)|nil,
--- on_select: fun(item: any|nil, index: integer|nil),
--- }
function M.select(opts)
	vim.ui.select(opts.items, {
		prompt = opts.title,
		kind = opts.kind,
		format_item = opts.format_item,
	}, opts.on_select)
end

---@param opts {
--- title: string,
--- items: any[],
--- key: fun(item: any): string,
--- format_item: AtlasPickerFormatItem,
--- initial_index: integer|nil,
--- on_select: fun(item: any|nil),
--- }
function M.find(opts)
	open_backend({
		title = opts.title,
		items = opts.items,
		format_item = opts.format_item,
		key = opts.key,
		multi = false,
		selected = {},
		initial_index = opts.initial_index,
		on_done = opts.on_select,
		on_cancel = function()
			opts.on_select(nil)
		end,
	})
end

---@param opts {
--- title: string,
--- items: any[],
--- key: fun(item: any): string,
--- format_item: AtlasPickerFormatItem,
--- preview_item: AtlasPickerPreviewItem,
--- on_select: fun(item: any|nil),
--- }
function M.select_with_preview(opts)
	open_backend({
		title = opts.title,
		items = opts.items,
		format_item = opts.format_item,
		key = opts.key,
		preview_item = opts.preview_item,
		multi = false,
		selected = {},
		on_done = opts.on_select,
		on_cancel = function()
			opts.on_select(nil)
		end,
	})
end

---@param opts {
--- title: string,
--- items: any[],
--- selected: any[],
--- key: fun(item: any): string,
--- format_item: AtlasPickerFormatItem,
--- on_done: fun(selected: any[]),
--- }
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
		multi = true,
		selected = opts.selected,
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
--- debounce_ms: integer|nil,
--- fetch_on_open: boolean|nil,
--- format_item: AtlasPickerFormatItem,
--- preview_item: AtlasPickerPreviewItem|nil,
--- fetch: AtlasPickerFetch,
--- on_select: fun(item: any),
--- on_cancel: fun()|nil,
--- }
function M.search(opts)
	open_backend({
		title = opts.title,
		items = opts.initial_items or {},
		format_item = opts.format_item,
		key = function(item)
			return tostring(item.id)
		end,
		preview_item = opts.preview_item,
		fetch = opts.fetch,
		multi = false,
		selected = {},
		fetch_on_open = opts.fetch_on_open,
		debounce_ms = opts.debounce_ms == nil and 250 or opts.debounce_ms,
		on_done = opts.on_select,
		on_cancel = opts.on_cancel,
	})
end

return M
