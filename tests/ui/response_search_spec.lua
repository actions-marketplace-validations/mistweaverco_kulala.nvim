local DB = require("kulala.db")
local ResponseManager = require("kulala.ui.response_manager")

describe("response history search", function()
  local saved_responses
  local saved_pos

  before_each(function()
    saved_responses = DB.global_data.responses
    saved_pos = DB.global_data.current_response_pos
    DB.global_data.responses = {}
    DB.global_data.current_response_pos = 0
    ResponseManager._test.reset_query_session()
  end)

  after_each(function()
    DB.global_data.responses = saved_responses
    DB.global_data.current_response_pos = saved_pos
  end)

  it("jumps to an in-memory response with the same history id", function()
    DB.global_data.responses = {
      { id = "a", history_id = 3, name = "first" },
      { id = "b", history_id = 9, name = "second" },
    }
    DB.global_data.current_response_pos = 1

    local response = ResponseManager.apply_history_entry {
      id = 9,
      method = "GET",
      url = "https://example.com",
      blockName = "second",
      statusCode = 200,
      responseBodyText = "ok",
      createdAt = "2026-06-22 14:02:00",
    }

    assert.are.equal(2, DB.global_data.current_response_pos)
    assert.are.equal("b", response.id)
    assert.are.equal(2, #DB.global_data.responses)
  end)

  it("appends a response when the history id is not in memory", function()
    local response = ResponseManager.apply_history_entry {
      id = 4,
      method = "POST",
      url = "https://example.com/post",
      blockName = "Create",
      statusCode = 201,
      requestHeaders = { Accept = "application/json" },
      requestBodyText = '{"a":1}',
      responseHeaders = { ["Content-Type"] = "application/json" },
      responseBodyText = '{"ok":true}',
      requestScriptsText = "pre",
      responseScriptsText = "post",
      createdAt = "2026-06-22 14:02:00",
    }

    assert.are.equal(1, #DB.global_data.responses)
    assert.are.equal(1, DB.global_data.current_response_pos)
    assert.are.equal("history:4", response.id)
    assert.are.equal(4, response.history_id)
    assert.are.equal("Create", response.name)
    assert.are.equal("POST", response.method)
    assert.are.equal(201, response.response_code)
    assert.are.equal('{"ok":true}', response.body)
    assert.are.equal("pre", response.script_pre_output)
    assert.are.equal("post", response.script_post_output)
    assert.are.equal("application/json", response.request.headers_tbl.Accept)
    assert.are.same({ ok = true }, response.json)
  end)

  it("keeps a match visible when the label does not contain the query", function()
    local label = "GET 200 · Login · https://example.com/x · 2026"
    local matches = { { id = 7, label = label } }
    local first = ResponseManager._test.picker_items("secret-token", matches)
    local again = ResponseManager._test.picker_items("secret-token", matches)

    assert.are.equal(1, #first)
    assert.are.equal(1, #again)
    assert.are.equal(7, again[1].history_id)
    assert.are.equal(label, again[1].label)
    assert.is_not_nil(again[1].text:find("secret-token", 1, true))
    assert.is_nil(label:find("secret-token", 1, true))
  end)

  it("does not let a stale empty result hide the same query", function()
    local calls = 0
    local session = ResponseManager._test.new_session()
    local function search_fn(query)
      calls = calls + 1
      if calls == 1 then
        ResponseManager._test.run_search(session, query, search_fn)
        return {}
      end
      return { { id = 9, label = "GET 200 · Login" } }
    end

    local result = ResponseManager._test.run_search(session, "token", search_fn)

    assert.are.equal(2, calls)
    assert.are.equal(1, #result)
    assert.are.equal(9, result[1].id)
    assert.are.equal(9, session.shown[1].id)
  end)

  it("returns matches again when the same query is searched twice", function()
    local calls = 0
    local session = ResponseManager._test.new_session()
    local function search_fn()
      calls = calls + 1
      return { { id = 3, label = "POST 201 · Create" } }
    end

    local first = ResponseManager._test.run_search(session, "token", search_fn)
    local second = ResponseManager._test.run_search(session, "token", search_fn)

    assert.are.equal(2, calls)
    assert.are.equal(1, #first)
    assert.are.equal(1, #second)
    assert.are.equal(3, second[1].id)
  end)

  it("runs only the latest callback after typing pauses", function()
    local callbacks = {}
    local cancelled = 0
    local function start_timer(ms, fn)
      assert.are.equal(200, ms)
      table.insert(callbacks, fn)
      return function()
        cancelled = cancelled + 1
      end
    end

    local debounce = ResponseManager._test.create_debouncer(200, start_timer)
    local ran = {}
    debounce(function()
      table.insert(ran, "first")
    end)
    debounce(function()
      table.insert(ran, "second")
    end)
    for _, fn in ipairs(callbacks) do
      fn()
    end

    assert.are.equal(1, cancelled)
    assert.are.same({ "second" }, ran)
  end)

  it("restores the last query for this Neovim session", function()
    assert.are.equal("", ResponseManager._test.initial_query())
    ResponseManager._test.remember_query("token")
    assert.are.equal("token", ResponseManager._test.initial_query())
    ResponseManager._test.remember_query("other")
    assert.are.equal("other", ResponseManager._test.initial_query())
  end)
end)
