local M = {}

local autocomplete_api = require("atlas.issues.providers.jira.api.autocomplete")

local MAX_COMPLETIONS = 10

-- JQL completion for `:AtlasJqlSearch`.
--
-- Completion flow per clause:
-- 1) Field stage:
--    show `visibleFieldNames` only (e.g. `assignee`, `assignee.property`).
-- 2) Operator stage:
--    after a field is selected, show only operators for that field.
-- 3) Value/function stage:
--    show `visibleFunctionNames` filtered by the selected field's `types`.
-- 4) Next-clause stage:
--    after a full value, show next fields first and reserved words last.
--    (connectors come from `jqlReservedWords`.)

---@param value string
---@return string
local function lower_trim(value)
	return vim.trim(tostring(value or "")):lower()
end

---@param value string
---@return string
local function function_insert(value)
	local v = vim.trim(tostring(value or ""))
	if v == "" then
		return ""
	end

	if v:find("%(") then
		return v
	end

	return v .. "()"
end

---@param value string
---@return string
local function normalize_field_token(value)
	local v = vim.trim(tostring(value or ""))
	if v:sub(1, 1) == '"' and v:sub(-1) == '"' then
		v = v:sub(2, -2)
	end
	return lower_trim(v)
end

--- Predefined static data for JQL autocomplete to ensure some level of functionality even if the API call fails or is slow.
---@type table
local STATIC_AUTOCOMPLETE_DATA = {
	visibleFieldNames = {
		{
			value = "assignee",
			displayName = "assignee",
			operators = {
				"in",
				"was in",
				"is",
				"is not",
				"was not in",
				"changed",
				"!=",
				"=",
				"was not",
				"not in",
				"was",
			},
			types = { "com.atlassian.jira.user.ApplicationUser" },
		},
		{
			value = "project",
			displayName = "project",
			operators = {
				"=",
				"!=",
				"in",
				"not in",
				"is",
				"is not",
				"was",
				"was in",
				"was not",
				"was not in",
				"changed",
			},
			types = { "com.atlassian.jira.project.Project" },
		},
		{
			value = "reporter",
			displayName = "reporter",
			operators = {
				"=",
				"!=",
				"in",
				"not in",
				"is",
				"is not",
				"was",
				"was in",
				"was not",
				"was not in",
				"changed",
			},
			types = { "com.atlassian.jira.user.ApplicationUser" },
		},
		{
			value = "status",
			displayName = "status",
			operators = {
				"=",
				"!=",
				"in",
				"not in",
				"is",
				"is not",
				"was",
				"was in",
				"was not",
				"was not in",
				"changed",
			},
			types = { "com.atlassian.jira.issue.status.Status" },
		},
		{
			value = "priority",
			displayName = "priority",
			operators = {
				"=",
				"!=",
				"in",
				"not in",
				"is",
				"is not",
				"was",
				"was in",
				"was not",
				"was not in",
				"changed",
			},
			types = { "com.atlassian.jira.issue.priority.Priority" },
		},
		{
			value = "summary",
			displayName = "summary",
			operators = { "~", "!~", "is", "is not" },
			types = { "java.lang.String" },
		},
		{
			value = "text",
			displayName = "text",
			operators = { "~", "!~" },
			types = { "java.lang.String" },
		},
	},
	visibleFunctionNames = {
		{ value = "currentUser", types = { "com.atlassian.jira.user.ApplicationUser" } },
		{ value = "membersOf", types = { "com.atlassian.crowd.embedded.api.Group" } },
		{ value = "startOfDay", types = { "java.util.Date" } },
		{ value = "endOfDay", types = { "java.util.Date" } },
		{ value = "startOfWeek", types = { "java.util.Date" } },
		{ value = "endOfWeek", types = { "java.util.Date" } },
		{ value = "startOfMonth", types = { "java.util.Date" } },
		{ value = "endOfMonth", types = { "java.util.Date" } },
		{ value = "openSprints", types = { "com.atlassian.greenhopper.service.sprint.Sprint" } },
	},
	jqlReservedWords = { "and", "or", "order", "by", "asc", "desc", "is", "in", "not", "empty", "null" },
}

---@param cmdline string
---@param cursorpos integer
---@return string
local function extract_query(cmdline, cursorpos)
	local raw = tostring(cmdline or "")
	local pos = math.max(0, math.min(tonumber(cursorpos) or #raw, #raw))
	local left = raw:sub(1, pos)
	left = left:gsub("^%s*:", "")

	local _, cmd_end = left:find("^[^%s]+%s*")
	if not cmd_end then
		return ""
	end

	return left:sub(cmd_end + 1)
end

---@param value string
---@param token string
---@return boolean
local function token_match(value, token)
	if token == "" then
		return true
	end

	local v = lower_trim(value)
	if #token <= 3 then
		return v:sub(1, #token) == token
	end

	return v:find(token, 1, true) ~= nil
end

---@param query string
---@return string[], boolean
local function tokenize_query(query)
	local text = tostring(query or "")
	local tokens = {}
	local buf = {}
	local in_quotes = false

	for i = 1, #text do
		local ch = text:sub(i, i)
		if ch == '"' then
			in_quotes = not in_quotes
			table.insert(buf, ch)
		elseif ch:match("%s") and not in_quotes then
			if #buf > 0 then
				table.insert(tokens, table.concat(buf))
				buf = {}
			end
		else
			table.insert(buf, ch)
		end
	end

	if #buf > 0 then
		table.insert(tokens, table.concat(buf))
	end

	return tokens, text:match("%s$") ~= nil
end

---@class JiraJqlFieldMeta
---@field value string
---@field display string
---@field operators string[]
---@field types table<string, boolean>

---@class JiraJqlFunctionMeta
---@field insert string
---@field value string
---@field types table<string, boolean>

---@param data table
---@return JiraJqlFieldMeta[], table<string, JiraJqlFieldMeta>, JiraJqlFunctionMeta[], string[]
local function build_autocomplete_index(data)
	---@type JiraJqlFieldMeta[]
	local fields = {}
	---@type table<string, JiraJqlFieldMeta>
	local fields_by_key = {}
	---@type JiraJqlFunctionMeta[]
	local functions = {}
	---@type string[]
	local reserved_words = {}
	local reserved_seen = {}

	for _, field in ipairs(data.visibleFieldNames or {}) do
		local value = field.value
		local ops = {}
		for _, op in ipairs(field.operators or {}) do
			table.insert(ops, op)
		end

		local types = {}
		for _, t in ipairs(field.types or {}) do
			types[t] = true
		end

		local meta = {
			value = value,
			display = field.displayName,
			operators = ops,
			types = types,
		}
		table.insert(fields, meta)
		fields_by_key[normalize_field_token(value)] = meta
	end

	for _, fn in ipairs(data.visibleFunctionNames or {}) do
		local value = fn.value
		local types = {}
		for _, t in ipairs(fn.types or {}) do
			types[t] = true
		end

		table.insert(functions, {
			value = value,
			insert = function_insert(value),
			types = types,
		})
	end

	for _, word in ipairs(data.jqlReservedWords or {}) do
		local upper = word:upper()
		if upper ~= "" and not reserved_seen[upper] then
			reserved_seen[upper] = true
			table.insert(reserved_words, upper)
		end
	end

	return fields, fields_by_key, functions, reserved_words
end

---@param value string
---@return string
local function field_completion(value)
	local v = vim.trim(tostring(value or ""))
	if v == "" then
		return ""
	end
	if v:find("%s") and not (v:sub(1, 1) == '"' and v:sub(-1) == '"') then
		return string.format('"%s"', v)
	end
	return v
end

---@param out string[]
---@param seen table<string, boolean>
---@param value string
local function push_unique(out, seen, value)
	local v = tostring(value or "")
	if v == "" or seen[v] then
		return
	end
	seen[v] = true
	table.insert(out, v)
end

---@param values string[]
---@param prefix string
---@return string[]
local function filter_by_prefix(values, prefix)
	local p = lower_trim(prefix or "")
	local out, seen = {}, {}
	for _, value in ipairs(values) do
		if p == "" or token_match(value, p) then
			push_unique(out, seen, value)
		end
	end
	table.sort(out, function(a, b)
		return lower_trim(a) < lower_trim(b)
	end)
	return out
end

---@param field_types table<string, boolean>
---@param function_types table<string, boolean>
---@return boolean
local function function_matches_field_types(field_types, function_types)
	local field_has_types = next(field_types) ~= nil
	local fn_has_types = next(function_types) ~= nil

	if not field_has_types or not fn_has_types then
		return true
	end

	for t, _ in pairs(function_types) do
		if field_types[t] then
			return true
		end
	end

	return false
end

---@param token string
---@return boolean
local function looks_like_complete_value(token)
	local t = vim.trim(tostring(token or ""))
	if t == "" then
		return false
	end

	if t:match("%)$") then
		return true
	end

	if t:match('^".*"$') or t:match("^'.*'$") then
		return true
	end

	if t:match("^%-?%d+%.?%d*$") then
		return true
	end

	local lower = lower_trim(t)
	return lower == "empty" or lower == "null" or lower == "true" or lower == "false"
end

---@param on_done fun(data: table|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_autocomplete_data(on_done, opts)
	opts = opts or {}
	return autocomplete_api.get_data(on_done, opts)
end

---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete_cmdline(arglead, cmdline, cursorpos)
	local query = extract_query(cmdline, cursorpos)
	local tokens, trailing_space = tokenize_query(query)
	local committed = tokens
	local partial = ""
	if not trailing_space and #tokens > 0 then
		committed = {}
		for i = 1, #tokens - 1 do
			table.insert(committed, tokens[i])
		end
		partial = tokens[#tokens]
	end

	local function sorted(values)
		table.sort(values, function(a, b)
			return lower_trim(a) < lower_trim(b)
		end)
		return values
	end

	local function connector_tokens(prefix, reserved_words)
		local p = lower_trim(prefix or "")
		local out, seen = {}, {}

		for _, word in ipairs(reserved_words or {}) do
			if p == "" or token_match(word, p) then
				push_unique(out, seen, word .. " ")
			end
		end

		return sorted(out)
	end

	local function merge_suggestions(first, second)
		local out, seen = {}, {}
		for _, v in ipairs(first or {}) do
			push_unique(out, seen, v)
		end
		for _, v in ipairs(second or {}) do
			push_unique(out, seen, v)
		end
		return out
	end

	local function cap(values)
		if #values <= MAX_COMPLETIONS then
			return values
		end
		local out = {}
		for i = 1, MAX_COMPLETIONS do
			out[i] = values[i]
		end
		return out
	end

	local function parse_active_clause(parts)
		local start_idx = 1
		local i = 1
		while i <= #parts do
			local lt = lower_trim(parts[i])
			if lt == "and" or lt == "or" then
				start_idx = i + 1
				i = i + 1
			elseif lt == "order" and i < #parts and lower_trim(parts[i + 1]) == "by" then
				start_idx = i + 2
				i = i + 2
			else
				i = i + 1
			end
		end

		local clause = {}
		for j = start_idx, #parts do
			table.insert(clause, parts[j])
		end

		local ended_with_connector = false
		if #clause == 0 and #parts > 0 then
			local last = lower_trim(parts[#parts])
			local prev = lower_trim(parts[#parts - 1] or "")
			ended_with_connector = last == "and" or last == "or" or (prev == "order" and last == "by")
		end

		return clause, ended_with_connector
	end

	local function static_suggestions()
		local static_fields, static_field_lookup = {}, {}
		local static_functions = {}
		local static_operators_by_field = {}
		local fields, fields_by_key, functions = build_autocomplete_index(STATIC_AUTOCOMPLETE_DATA)

		for _, field in ipairs(fields) do
			local candidate = field_completion(field.value)
			if candidate ~= "" then
				table.insert(static_fields, candidate)
			end
			local field_key = normalize_field_token(field.value)
			static_field_lookup[field_key] = true
			static_operators_by_field[field_key] = {}
			for _, op in ipairs(field.operators or {}) do
				table.insert(static_operators_by_field[field_key], tostring(op) .. " ")
			end
		end

		for _, fn in ipairs(functions) do
			if fn.insert and fn.insert ~= "" then
				table.insert(static_functions, fn.insert)
			end
		end

		return static_fields, static_functions, static_operators_by_field, static_field_lookup
	end

	local function parse_operator_match(ops, operator_words)
		local matched_op = nil
		local matched_words = 0
		for _, op in ipairs(ops) do
			local op_words, _ = tokenize_query(op)
			if #op_words > 0 and #operator_words >= #op_words then
				local ok = true
				for idx = 1, #op_words do
					if lower_trim(operator_words[idx]) ~= lower_trim(op_words[idx]) then
						ok = false
						break
					end
				end
				if ok and #op_words > matched_words then
					matched_op = op
					matched_words = #op_words
				end
			end
		end
		return matched_op, matched_words
	end

	local function has_operator_prefix(ops, prefix)
		local p = lower_trim(prefix)
		if p == "" then
			return true
		end
		for _, op in ipairs(ops) do
			if lower_trim(op):sub(1, #p) == p then
				return true
			end
		end
		return false
	end

	local static_fields, static_functions, static_operators_by_field, static_field_lookup = static_suggestions()
	local static_reserved = {}

	local cached, ok = autocomplete_api.get_cached_data()
	if not ok or type(cached) ~= "table" then
		local clause_tokens, after_connector = parse_active_clause(committed)
		local prefix = partial ~= "" and partial or arglead

		if #clause_tokens == 0 then
			if after_connector then
				return cap(
					merge_suggestions(
						connector_tokens(prefix, static_reserved),
						filter_by_prefix(static_fields, prefix)
					)
				)
			end
			return cap(filter_by_prefix(static_fields, prefix))
		end

		if #clause_tokens == 1 then
			local maybe_field = normalize_field_token(clause_tokens[1])
			local looks_like_field = maybe_field ~= "" and static_field_lookup[maybe_field] == true
			if looks_like_field then
				return cap(filter_by_prefix(static_operators_by_field[maybe_field] or {}, prefix))
			end
		end

		if #clause_tokens >= 2 then
			local maybe_connector_prefix = partial ~= "" and partial or ""
			if #clause_tokens >= 3 then
				return cap(
					merge_suggestions(
						filter_by_prefix(static_fields, maybe_connector_prefix),
						connector_tokens(maybe_connector_prefix, static_reserved)
					)
				)
			end
			return cap(filter_by_prefix(static_functions, prefix))
		end

		return cap(filter_by_prefix(static_fields, prefix))
	end

	local fields, fields_by_key, functions, reserved_words = build_autocomplete_index(cached)

	local function suggest_fields(prefix)
		local items, seen = {}, {}
		for _, field in ipairs(fields) do
			local candidate = field_completion(field.value)
			if candidate ~= "" then
				local p = lower_trim(prefix or "")
				if p == "" or token_match(field.value, p) or token_match(field.display, p) then
					push_unique(items, seen, candidate)
				end
			end
		end
		return cap(sorted(items))
	end

	local clause_tokens, after_connector = parse_active_clause(committed)
	local input_prefix = partial ~= "" and partial or arglead

	if #clause_tokens == 0 then
		if after_connector then
			return cap(merge_suggestions(connector_tokens(input_prefix, reserved_words), suggest_fields(input_prefix)))
		end
		return cap(suggest_fields(input_prefix))
	end

	local field_token = clause_tokens[1]
	local field_meta = fields_by_key[normalize_field_token(field_token)]
	if not field_meta then
		local base = suggest_fields(input_prefix ~= "" and input_prefix or field_token)
		if after_connector then
			return cap(merge_suggestions(connector_tokens(input_prefix, reserved_words), base))
		end
		return cap(base)
	end

	local operator_words = {}
	for idx = 2, #clause_tokens do
		table.insert(operator_words, clause_tokens[idx])
	end

	local normalized_ops = {}
	for _, op in ipairs(field_meta.operators) do
		if vim.trim(op) ~= "" then
			table.insert(normalized_ops, vim.trim(op))
		end
	end

	local operator_input_words = {}
	for _, word in ipairs(operator_words) do
		table.insert(operator_input_words, word)
	end
	if partial ~= "" then
		table.insert(operator_input_words, partial)
	end
	local operator_input = vim.trim(table.concat(operator_input_words, " "))

	local matched_operator, matched_op_words = parse_operator_match(normalized_ops, operator_words)
	local still_typing_operator = false
	if partial ~= "" and #operator_words >= matched_op_words then
		still_typing_operator = has_operator_prefix(normalized_ops, operator_input)
	end

	if matched_operator == nil or still_typing_operator then
		local op_items, seen = {}, {}
		for _, op in ipairs(normalized_ops) do
			if operator_input == "" or token_match(op, lower_trim(operator_input)) then
				push_unique(op_items, seen, op .. " ")
			end
		end
		return cap(sorted(op_items))
	end

	local value_tokens = {}
	for idx = matched_op_words + 1, #operator_words do
		table.insert(value_tokens, operator_words[idx])
	end

	local has_complete_value = #value_tokens > 0 or (partial ~= "" and looks_like_complete_value(partial))

	if not has_complete_value then
		local function_prefix = partial ~= "" and partial or ""
		local fn_items, seen = {}, {}
		for _, fn in ipairs(functions) do
			local insert = vim.trim(fn.insert or "")
			if insert ~= "" and function_matches_field_types(field_meta.types, fn.types) then
				if
					function_prefix == ""
					or token_match(fn.value, lower_trim(function_prefix))
					or token_match(insert, lower_trim(function_prefix))
				then
					push_unique(fn_items, seen, insert)
				end
			end
		end
		return cap(sorted(fn_items))
	end

	local connector_prefix = ""
	if #value_tokens > 0 and partial ~= "" then
		connector_prefix = partial
	end

	local connectors = connector_tokens(connector_prefix, reserved_words)
	local next_fields = suggest_fields(connector_prefix)
	return cap(merge_suggestions(next_fields, connectors))
end

return M
