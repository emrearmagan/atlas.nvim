local M = {}

local _cached_version = nil

---@param lines string[]
---@param spans table[]
---@param text string
---@param hl_group string|nil
---@param padding integer|nil
function M.push(lines, spans, text, hl_group, padding)
	local pad = padding or 0
	local prefix = pad > 0 and string.rep(" ", pad) or ""
	table.insert(lines, prefix .. text)
	if hl_group then
		table.insert(spans, {
			line = #lines - 1,
			start_col = pad,
			end_col = pad + #text,
			hl_group = hl_group,
		})
	end
end

function M.append_block(lines, spans, block)
	local base = #lines
	for _, line in ipairs(block.lines or {}) do
		table.insert(lines, line)
	end
	for _, span in ipairs(block.highlights or {}) do
		if type(span) == "table" and span.line_hl_group ~= nil then
			table.insert(spans, {
				line = base + span.line,
				line_hl_group = span.line_hl_group,
			})
		else
			table.insert(spans, {
				line = base + span.line,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end
end

function M.get_version()
	if _cached_version then
		return _cached_version
	end

	local ok, version = pcall(function()
		return vim.fn.system(
			"git -C " .. vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h") .. " describe --tags --abbrev=0"
		)
	end)

	if ok and type(version) == "string" and version ~= "" then
		_cached_version = version:gsub("%s+", "")
	else
		_cached_version = "dev"
	end

	return _cached_version
end

---Convert UTC date components to a Unix epoch without relying on the system timezone
---@param y integer @ year (e.g. 2026)
---@param m integer @ month 1-12
---@param d integer @ day 1-31
---@param hh integer
---@param mm integer
---@param ss integer
---@return integer
local function utc_epoch(y, m, d, hh, mm, ss)
	y = y - (m <= 2 and 1 or 0)
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + hh * 3600 + mm * 60 + ss
end

function M.relative_time(iso)
	if type(iso) ~= "string" or iso == "" then
		return "-"
	end

	local y, mo, d, hh, mm, ss = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
	if not y then
		return "-"
	end

	local then_epoch = utc_epoch(tonumber(y), tonumber(mo), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss))

	local delta = os.time() - then_epoch
	if delta < 0 then
		delta = 0
	end

	if delta < 5 then
		return "now"
	end
	if delta < 60 then
		return string.format("%ds", delta)
	end

	local minutes = math.floor(delta / 60)
	if minutes < 60 then
		return string.format("%dm", minutes)
	end

	local hours = math.floor(minutes / 60)
	if hours < 24 then
		return string.format("%dh", hours)
	end

	local days = math.floor(hours / 24)
	if days < 7 then
		return string.format("%dd", days)
	end

	local weeks = math.floor(days / 7)
	if weeks < 5 then
		return string.format("%dw", weeks)
	end

	local months = math.floor(days / 30)
	if months < 12 then
		return string.format("%dmo", months)
	end

	local years = math.floor(days / 365)
	return string.format("%dy", years)
end

---@param iso string|nil
---@return string
function M.relative_time_text(iso)
	local rel = M.relative_time(iso)
	if rel == "-" then
		return "-"
	end
	if rel == "now" then
		return "just now"
	end

	local n, unit = rel:match("^(%d+)(%a+)$")
	if n == nil or unit == nil then
		return rel
	end

	n = tonumber(n) or 0
	local labels = {
		s = "second",
		m = "minute",
		h = "hour",
		d = "day",
		w = "week",
		mo = "month",
		y = "year",
	}
	local base = labels[unit] or unit
	local suffix = n == 1 and "" or "s"
	return string.format("%d %s%s ago", n, base, suffix)
end

---@param iso string|nil
---@return string
function M.format_date(iso)
	if type(iso) ~= "string" or iso == "" then
		return ""
	end

	local ymd = iso:match("^(%d%d%d%d%-%d%d%-%d%d)")
	if ymd ~= nil then
		return ymd
	end

	return ""
end

---@param bytes number|string|nil
---@return string
function M.human_size(bytes)
	local n = tonumber(bytes) or 0
	if n < 0 then
		n = 0
	end

	local units = { "B", "KB", "MB", "GB", "TB" }
	local i = 1
	while n >= 1024 and i < #units do
		n = n / 1024
		i = i + 1
	end

	if i == 1 then
		return string.format("%d %s", math.floor(n), units[i])
	end

	return string.format("%.1f %s", n, units[i])
end

---@param seconds number|string|nil
---@return string
function M.human_duration(seconds)
	local total = tonumber(seconds)
	if total == nil then
		return ""
	end

	if total < 0 then
		total = 0
	end

	local minutes = math.floor(total / 60)
	if minutes < 60 then
		return string.format("%dm", minutes)
	end

	local hours = math.floor(minutes / 60)
	local rem_minutes = minutes % 60
	if hours < 24 then
		if rem_minutes == 0 then
			return string.format("%dh", hours)
		end
		return string.format("%dh %dm", hours, rem_minutes)
	end

	local days = math.floor(hours / 24)
	local rem_hours = hours % 24
	if rem_hours == 0 then
		return string.format("%dd", days)
	end
	return string.format("%dd %dh", days, rem_hours)
end

---@param list table
---@param value any
function M.insert_if(list, value)
	if value ~= nil then
		table.insert(list, value)
	end
end

---@param value any
---@return string
function M.encode_pretty_json(value)
	local ok, encoded = pcall(vim.json.encode, value, { indent = "  " })
	if ok and type(encoded) == "string" and encoded ~= "" then
		return encoded
	end

	local fallback_ok, fallback = pcall(vim.fn.json_encode, value)
	if fallback_ok and type(fallback) == "string" and fallback ~= "" then
		return fallback
	end

	return "{}"
end

---@param text string|nil
---@return string[]
function M.sanitize_lines(text)
	if type(text) ~= "string" or text == "" then
		return { "-" }
	end

	local out = {}
	text = text:gsub("\r\n", "\n")
	for line in (text .. "\n"):gmatch("(.-)\n") do
		table.insert(out, line)
	end

	if #out == 0 then
		return { "-" }
	end

	return out
end

local strwidth = vim.api.nvim_strwidth
local strcharpart = vim.fn.strcharpart
local strchars = vim.fn.strchars

---@param str string
---@param max_dw integer
---@param from_start? boolean
---@return string
function M.truncate(str, max_dw, from_start)
	local ellipsis = "…"
	if max_dw < 1 then
		return ellipsis
	end
	if strwidth(str) <= max_dw then
		return str
	end

	local nchars = strchars(str)
	if from_start then
		for i = 1, nchars do
			local tail = strcharpart(str, i)
			if strwidth(tail) <= max_dw - 1 then
				return ellipsis .. tail
			end
		end
		return ellipsis
	end

	for i = nchars - 1, 0, -1 do
		local head = strcharpart(str, 0, i)
		if strwidth(head) <= max_dw - 1 then
			return head .. ellipsis
		end
	end
	return ellipsis
end

---@param name string|nil
---@param max_width integer
---@return string
function M.shorten_name(name, max_width)
	if type(name) ~= "string" then
		return ""
	end
	if strwidth(name) <= max_width then
		return name
	end
	local parts = vim.split(name, " ", { plain = true, trimempty = true })
	if #parts <= 1 then
		return M.truncate(name, max_width)
	end
	for i = #parts, 2, -1 do
		parts[i] = parts[i]:sub(1, 1) .. "."
		local candidate = table.concat(parts, " ")
		if strwidth(candidate) <= max_width then
			return candidate
		end
	end
	return M.truncate(table.concat(parts, " "), max_width)
end

---@param text string
---@param max_dw integer
---@return string[]
function M.wrap_line(text, max_dw)
	if max_dw < 2 or strwidth(text) <= max_dw then
		return { text }
	end

	local result = {}
	local remaining = text
	while remaining ~= "" do
		if strwidth(remaining) <= max_dw then
			result[#result + 1] = remaining
			break
		end

		local nchars = strchars(remaining)
		local cut = nchars
		for i = nchars - 1, 1, -1 do
			if strwidth(strcharpart(remaining, 0, i)) <= max_dw then
				cut = i
				break
			end
		end

		local last_space = nil
		local half = math.floor(cut * 0.5)
		for i = cut, half, -1 do
			if strcharpart(remaining, i - 1, 1) == " " then
				last_space = i
				break
			end
		end

		if last_space then
			result[#result + 1] = strcharpart(remaining, 0, last_space - 1)
			remaining = strcharpart(remaining, last_space)
		else
			result[#result + 1] = strcharpart(remaining, 0, cut)
			remaining = strcharpart(remaining, cut)
		end
	end

	return result
end

---@param text string|nil
---@return string
function M.strip_markup(text)
	local s = tostring(text or "")
	s = s:gsub("\r\n", "\n")
	s = s:gsub("<!%-%-.-%-%->", "")
	return vim.trim(s)
end

return M
