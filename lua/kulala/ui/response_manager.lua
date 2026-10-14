local has_fzf, fzf = pcall(require, "fzf-lua")
local has_telescope = pcall(require, "telescope")
local has_snacks, snacks_picker = pcall(require, "snacks.picker")

local Config = require("kulala.config")
local DB = require("kulala.db")
local Json = require("kulala.utils.json")
local KulalaCore = require("kulala.cmd.kulala_core_bridge")
local Logger = require("kulala.logger")
local Ui = require("kulala.ui")

local M = {}

local last_error

---A newer search must win when an older one finishes last.
---That happens when a live picker starts a second query while the first
---`vim.wait` is still running, and the first call then returns an empty list.
---@param state { generation: number, shown: table[] }
---@param query string
---@param search_fn fun(query: string): table[]|nil
---@return table[]
local function run_search(state, query, search_fn)
  state.generation = state.generation + 1
  local generation = state.generation
  local matches = search_fn(query) or {}
  if generation ~= state.generation then return state.shown end
  state.shown = matches
  return state.shown
end

local search_state = { generation = 0, shown = {} }

local SEARCH_DEBOUNCE_MS = 200

---Last query typed in this Neovim session. Nil until the user edits the prompt.
local session_query ---@type string|nil

---Query the next live finder call should execute immediately.
local debounce_due ---@type string|nil

local function remember_query(query)
  session_query = query or ""
end

---Trailing debounce. `start_timer(ms, fn)` returns a cancel function.
---@param delay_ms number
---@param start_timer fun(ms: number, fn: fun()): fun()|nil
---@return fun(run: fun())
local function create_debouncer(delay_ms, start_timer)
  local generation = 0
  local cancel
  return function(run)
    generation = generation + 1
    local gen = generation
    if cancel then
      cancel()
      cancel = nil
    end
    cancel = start_timer(delay_ms, function()
      cancel = nil
      if gen ~= generation then return end
      run()
    end)
  end
end

local function start_uv_timer(ms, fn)
  local timer = vim.uv.new_timer()
  local closed = false
  local function close()
    if closed then return end
    closed = true
    timer:stop()
    if not timer:is_closing() then timer:close() end
  end
  timer:start(ms, 0, function()
    close()
    vim.schedule(fn)
  end)
  return close
end

local debounce_query = create_debouncer(SEARCH_DEBOUNCE_MS, start_uv_timer)

---Picker rows stay visible when the UI also filters by the typed query.
---A body-only match is not in the label, so the query is appended to the text.
---@param query string
---@param match table
---@return table
local function picker_item(query, match)
  local label = match.label or tostring(match.id)
  local text = label
  if query ~= "" and not text:find(query, 1, true) then text = text .. " " .. query end
  return {
    id = match.id,
    history_id = match.id,
    label = label,
    text = text,
    snippets = match.snippets,
    line = tostring(match.id) .. "\t" .. text,
  }
end

local function search_options()
  return (Config.options.ui and Config.options.ui.response_search) or {}
end

local function default_query()
  return search_options().default_query or ""
end

---@param headers table|nil
---@return string
local function headers_text(headers)
  if type(headers) ~= "table" then return "" end
  local lines = {}
  for key, value in pairs(headers) do
    table.insert(lines, ("%s: %s"):format(key, tostring(value)))
  end
  table.sort(lines)
  if #lines == 0 then return "" end
  return table.concat(lines, "\n") .. "\n\n"
end

---@param created_at string|nil
---@return number
local function history_time(created_at)
  if type(created_at) ~= "string" or created_at == "" then return vim.fn.localtime() end
  local parsed = vim.fn.strptime("%Y-%m-%d %H:%M:%S", created_at)
  if type(parsed) == "number" and parsed > 0 then return parsed end
  return vim.fn.localtime()
end

---@param query string
---@return table[]
local function fetch_matches(query)
  local res, err = KulalaCore.search_responses {
    query = query or "",
    fuzzy = search_options().fuzzy == true,
  }
  if not res then
    local message = err or "Failed to search responses"
    if message ~= last_error then
      last_error = message
      Logger.error(message)
    end
    return {}
  end
  if res.success == false then
    local message = res.error or "Failed to search responses"
    if message ~= last_error then
      last_error = message
      Logger.error(message)
    end
    return {}
  end
  last_error = nil
  return res.matches or {}
end

---@param query string
---@return table[]
local function search_matches(query)
  return run_search(search_state, query, fetch_matches)
end

local function initial_query()
  if session_query ~= nil then return session_query end
  return default_query()
end

---@param query string
---@return table[]
local function cached_items(query)
  local items = {}
  for _, match in ipairs(search_state.shown or {}) do
    table.insert(items, picker_item(query, match))
  end
  return items
end

---Run the core search after typing pauses. Until then, return nil.
---@param query string
---@param fire fun()
---@return table[]|nil
local function debounced_matches(query, fire)
  remember_query(query)
  if debounce_due == query then
    debounce_due = nil
    return search_matches(query)
  end
  debounce_query(function()
    debounce_due = query
    fire()
  end)
  return nil
end

---@param item table|nil
---@return string[]
local function preview_lines(item)
  if not item then return {} end
  local lines = { item.label or item.text or "" }
  local snippets = item.snippets or {}
  if #snippets == 0 then
    table.insert(lines, "")
    table.insert(lines, "No match excerpt")
    return lines
  end
  for _, snippet in ipairs(snippets) do
    table.insert(lines, "")
    table.insert(lines, (snippet.field or "match") .. ":")
    table.insert(lines, snippet.text or "")
  end
  return lines
end

---Build a UI response from a kulala-core history row.
---@param entry table
---@return Response
function M.response_from_history(entry)
  local body = entry.responseBodyText or ""
  local response_code = tonumber(entry.statusCode) or 0
  ---@type Response
  return {
    id = "history:" .. tostring(entry.id),
    history_id = tonumber(entry.id),
    name = entry.blockName or "",
    url = entry.url or "",
    method = entry.method or "",
    request = {
      url = entry.url or "",
      headers_tbl = entry.requestHeaders or {},
      body = entry.requestBodyText or "",
    },
    status = true,
    code = 0,
    response_code = response_code,
    duration = 0,
    time = history_time(entry.createdAt),
    body = body,
    body_raw = body,
    json = Json.parse(body) or {},
    headers = headers_text(entry.responseHeaders),
    headers_tbl = entry.responseHeaders or {},
    cookies = {},
    errors = "",
    stats = "",
    script_pre_output = entry.requestScriptsText or "",
    script_post_output = entry.responseScriptsText or "",
    assert_output = {},
    assert_status = true,
    file = "",
    buf = 0,
    buf_name = "",
    line = 0,
    _kulala_core = true,
  }
end

---Focus a history row in the in-memory list, appending it when it is new.
---@param entry table
---@return Response
function M.apply_history_entry(entry)
  local history_id = tonumber(entry.id)
  local responses = DB.global_update().responses
  if history_id then
    for index, response in ipairs(responses) do
      if tonumber(response.history_id) == history_id then
        DB.global_update().current_response_pos = index
        return response
      end
    end
  end

  local response = M.response_from_history(entry)
  table.insert(responses, response)
  DB.global_update().current_response_pos = #responses
  return response
end

---@param id number
function M.open_history_id(id)
  local entry, err = KulalaCore.get_history_entry(id)
  if not entry then
    Logger.error(err or "History entry not found")
    return
  end
  M.apply_history_entry(entry)
  Ui.open_default_view()
end

local function open_snacks()
  snacks_picker {
    title = "Search responses",
    live = true,
    supports_live = true,
    search = initial_query(),
    matcher = { fuzzy = false, sort_empty = false },
    layout = Config.options.ui.pickers.snacks.layout,
    format = function(item)
      return { { item.label or item.text or "" } }
    end,
    finder = function(_, ctx)
      local query = ""
      if ctx and ctx.filter and type(ctx.filter.search) == "string" then query = ctx.filter.search end
      local picker = ctx and ctx.picker
      local matches = debounced_matches(query, function()
        if not picker or picker.closed then return end
        local current = ""
        if picker.input and picker.input.filter and type(picker.input.filter.search) == "string" then
          current = picker.input.filter.search
        end
        if current ~= query then return end
        picker:find { refresh = true }
      end)
      if not matches then return cached_items(query) end
      local items = {}
      for _, match in ipairs(matches) do
        table.insert(items, picker_item(query, match))
      end
      return items
    end,
    preview = function(ctx)
      local bufnr = ctx.picker.layout.wins.preview.buf
      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, preview_lines(ctx.item))
      return true
    end,
    win = {
      preview = { title = "Match" },
      list = { title = "Responses" },
    },
    confirm = function(ctx, item)
      ctx:close()
      if item and item.history_id then M.open_history_id(item.history_id) end
    end,
  }
end

local function open_telescope()
  local action_state = require("telescope.actions.state")
  local actions = require("telescope.actions")
  local finders = require("telescope.finders")
  local pickers = require("telescope.pickers")
  local previewers = require("telescope.previewers")
  local sorters = require("telescope.sorters")

  local sorter = sorters.Sorter:new {
    discard = false,
    scoring_function = function()
      return 1
    end,
    highlighter = function()
      return {}
    end,
  }

  local picker
  picker = pickers.new({}, {
    prompt_title = "Search responses",
    results_title = "Responses",
    default_text = initial_query(),
    cache_picker = false,
    finder = finders.new_dynamic {
      fn = function(prompt)
        prompt = prompt or ""
        local matches = debounced_matches(prompt, function()
          if picker and picker._on_lines then picker._on_lines() end
        end)
        local source = matches
        local items = {}
        if source then
          for index, match in ipairs(source) do
            local item = picker_item(prompt, match)
            item.index = index
            table.insert(items, item)
          end
        else
          for index, item in ipairs(cached_items(prompt)) do
            item.index = index
            table.insert(items, item)
          end
        end
        return items
      end,
      entry_maker = function(item)
        return {
          value = item,
          display = item.label or tostring(item.id),
          ordinal = item.text or item.label or "",
          index = item.index or 1,
        }
      end,
    },
      sorter = sorter,
      previewer = previewers.new_buffer_previewer {
        title = "Match",
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines(entry.value))
        end,
      },
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection and selection.value and selection.value.id then M.open_history_id(selection.value.id) end
      end)
      return true
    end,
  })
  picker:find()
end

local function fzf_query(args)
  if type(args) == "table" then return args[1] or "" end
  if type(args) == "string" then return args end
  return ""
end

local function remember_fzf_opts(opts)
  if type(opts) == "table" and type(opts.last_query) == "string" then remember_query(opts.last_query) end
end

local function open_fzf()
  fzf.fzf_live(function(args)
    local query = fzf_query(args)
    remember_query(query)
    local lines = {}
    for _, match in ipairs(search_matches(query)) do
      table.insert(lines, picker_item(query, match).line)
    end
    return lines
  end, {
    prompt = "Search responses> ",
    query = initial_query(),
    query_delay = SEARCH_DEBOUNCE_MS,
    exec_empty_query = true,
    resume = false,
    fzf_opts = {
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
    },
    actions = {
      ["default"] = function(selected, opts)
        remember_fzf_opts(opts)
        for _, line in ipairs(selected or {}) do
          local id = tonumber(tostring(line):match("^(%d+)\t"))
          if id then
            M.open_history_id(id)
            return
          end
        end
      end,
      ["esc"] = function(_, opts)
        remember_fzf_opts(opts)
      end,
      ["ctrl-c"] = function(_, opts)
        remember_fzf_opts(opts)
      end,
    },
  })
end

local function open_selector()
  local query = vim.fn.input { prompt = "Search responses: ", default = initial_query() }
  if query == nil then return end
  remember_query(query)
  local matches = search_matches(query)
  if #matches == 0 then
    Logger.info("No matching responses")
    return
  end
  vim.ui.select(matches, {
    prompt = "Responses",
    format_item = function(match)
      return match.label or tostring(match.id)
    end,
  }, function(match)
    if match and match.id then M.open_history_id(match.id) end
  end)
end

M.open = function()
  last_error = nil
  if has_fzf and type(fzf.fzf_live) == "function" then
    local ok = pcall(open_fzf)
    if ok then return end
  end
  if has_snacks then
    local ok = pcall(open_snacks)
    if ok then return end
  end
  if has_telescope then
    open_telescope()
    return
  end
  open_selector()
end

M._test = {
  new_session = function()
    return { generation = 0, shown = {} }
  end,
  run_search = run_search,
  create_debouncer = create_debouncer,
  remember_query = remember_query,
  initial_query = initial_query,
  reset_query_session = function()
    session_query = nil
    debounce_due = nil
  end,
  picker_items = function(query, matches)
    local items = {}
    for _, match in ipairs(matches) do
      table.insert(items, picker_item(query, match))
    end
    return items
  end,
}

return M
