describe("pulls.diff.images", function()
	local original_vim, original_io, original_loaded, original_preload
	local images, snacks, image, view, pending, attached, cleaned, writes, keys
	local buffers, windows
	local modules = { "atlas.pulls.diff.images", "snacks", "snacks.image" }

	before_each(function()
		original_vim, original_io = vim, io
		original_loaded, original_preload = {}, {}
		for _, name in ipairs(modules) do
			original_loaded[name], original_preload[name] = package.loaded[name], package.preload[name]
			package.loaded[name], package.preload[name] = nil, nil
		end
		pending, attached, cleaned, writes, keys = {}, {}, {}, {}, {}
		buffers = { [1] = {}, [2] = {} }
		windows = { [11] = 1, [12] = 2 }
		snacks = { config = { image = { enabled = true } } }
		image = {
			supports_file = function(path)
				return path:match("%.png$") ~= nil
			end,
			supports_terminal = function()
				return true
			end,
			terminal = {
				detect = function(callback)
					pending[#pending + 1] = callback
				end,
			},
			placement = {
				clean = function(buf)
					cleaned[#cleaned + 1] = buf
				end,
				new = function(buf, src, options)
					attached[#attached + 1] = { buf = buf, src = src, options = options }
				end,
			},
		}
		package.loaded.snacks = snacks
		package.loaded["snacks.image"] = image
		_G.vim = {
			api = {
				nvim_buf_is_valid = function(buf)
					return buffers[buf] ~= nil
				end,
				nvim_win_is_valid = function(win)
					return windows[win] ~= nil
				end,
				nvim_win_get_buf = function(win)
					return windows[win]
				end,
				nvim_buf_get_lines = function(buf)
					return buffers[buf].lines or { "Binary file" }
				end,
				nvim_buf_set_text = function(buf, start_row, start_col, end_row, end_col, text)
					local lines = buffers[buf].lines or { "Binary file" }
					lines[start_row + 1] = lines[start_row + 1]:sub(1, start_col)
						.. text[1]
						.. lines[end_row + 1]:sub(end_col + 1)
					buffers[buf].lines = lines
				end,
			},
			fn = {
				tempname = function()
					return "/images-test"
				end,
				sha256 = function(key)
					keys[#keys + 1] = key
					return tostring(#keys)
				end,
				fnamemodify = function(path)
					return path:match("%.([^%.]+)$")
				end,
				filereadable = function()
					return 0
				end,
				mkdir = function() end,
			},
			bo = buffers,
		}
		-- selene: allow(global_usage)
		_G.io = setmetatable({
			open = function(path, mode)
				if path:sub(1, 13) ~= "/images-test/" then
					return original_io.open(path, mode)
				end
				assert.equals("wb", mode)
				return {
					write = function(_, content)
						writes[path] = content
						return true
					end,
					close = function()
						return true
					end,
				}
			end,
		}, { __index = original_io })
		view = {
			result = { root = "/repo", base_revision = "base", head_revision = "head" },
			left = { buf = 1, win = 11 },
			right = { buf = 2, win = 12 },
			document = {
				file = { status = "modified", old_path = "old.png", path = "new.png" },
				binary = true,
				contents = {
					old = { binary_content = "old\0\r\n\255" },
					new = { binary_content = "new\0\r\n\255" },
				},
			},
		}
		images = require("atlas.pulls.diff.images")
	end)

	after_each(function()
		_G.vim = original_vim
		-- selene: allow(global_usage)
		_G.io = original_io
		for _, name in ipairs(modules) do
			package.loaded[name], package.preload[name] = original_loaded[name], original_preload[name]
		end
	end)

	it("requires enabled Snacks image support and a supported extension", function()
		assert.is_true(images.supports_file("image.png"))
		assert.is_false(images.supports_file("archive.zip"))
		snacks.config.image.enabled = false
		assert.is_false(images.supports_file("image.png"))
		package.loaded.snacks = nil
		package.preload.snacks = function()
			error("Snacks is not installed")
		end
		assert.is_false(images.supports_file("image.png"))
	end)

	it("attaches renamed image revisions with their exact binary bytes", function()
		images.attach(view)
		assert.equals(0, #attached)
		pending[1]()
		assert.same({ "/repo:base:old.png", "/repo:head:new.png" }, keys)
		assert.equals(1, attached[1].buf)
		assert.equals(2, attached[2].buf)
		assert.equals(view.document.contents.old.binary_content, writes[attached[1].src])
		assert.equals(view.document.contents.new.binary_content, writes[attached[2].src])
		assert.same({ "" }, buffers[1].lines)
		assert.same({ "" }, buffers[2].lines)
		assert.is_true(attached[1].options.inline)
		assert.is_true(attached[1].options.conceal)
		assert.is_true(attached[1].options.auto_resize)
	end)

	it("shows only the new revision for an added image", function()
		view.document.file.status = "added"
		view.document.contents.old.binary_content = nil
		view.left.win = nil
		images.attach(view)
		pending[1]()
		assert.equals(1, #attached)
		assert.equals(2, attached[1].buf)
		assert.same({ "/repo:head:new.png" }, keys)
	end)

	it("shows the base revision in the right pane for a deleted image", function()
		view.document.file.status = "deleted"
		view.document.contents.new.binary_content = nil
		view.left.win = nil
		images.attach(view)
		pending[1]()
		assert.equals(1, #attached)
		assert.equals(2, attached[1].buf)
		assert.same({ "/repo:base:old.png" }, keys)
		assert.equals(view.document.contents.old.binary_content, writes[attached[1].src])
	end)

	it("invalidates terminal detection callbacks when the same document is redisplayed", function()
		images.attach(view)
		images.clear(view)
		images.attach(view)
		pending[1]()
		assert.equals(0, #attached)
		pending[2]()
		assert.equals(2, #attached)
	end)

	it("does not attach a document that changed while terminal detection was pending", function()
		images.attach(view)
		view.document = nil
		pending[1]()
		assert.equals(0, #attached)
	end)

	it("skips panes whose windows no longer contain their buffers", function()
		images.attach(view)
		windows[11] = nil
		windows[12] = 99
		pending[1]()
		assert.equals(0, #attached)
	end)

	it("keeps placeholders when the terminal does not support images", function()
		image.supports_terminal = function()
			return false
		end
		images.attach(view)
		pending[1]()
		assert.equals(0, #attached)
		assert.is_nil(buffers[1].lines)
		assert.is_nil(buffers[2].lines)
	end)

	it("cleans tracked buffers after the document and image config are cleared", function()
		images.attach(view)
		pending[1]()
		view.document = nil
		snacks.config.image.enabled = false
		images.clear(view)
		table.sort(cleaned)
		assert.same({ 1, 2 }, cleaned)
		images.clear(view)
		assert.equals(2, #cleaned)
	end)
end)
