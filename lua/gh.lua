local M = {}

local github_dir = vim.fn.expand("~/Documents/GitHub")
local cache_dir = vim.fn.stdpath("cache") .. "/gh"
vim.fn.mkdir(cache_dir, "p")

-- Extra GitHub orgs/users not returned by `gh api user/orgs`
local extra_orgs = { "iolotech", "botpress" }

-- Background refresh interval (ms). 5 min = 300_000.
local AUTO_REFRESH_MS = 300000

-- ============================================================
-- Cache (JSON on disk, keyed by name)
-- ============================================================

local function cache_path(key)
  return cache_dir .. "/" .. key:gsub("[/\\]", "_") .. ".json"
end

local function cache_read(key)
  local f = io.open(cache_path(key), "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    return nil
  end
  local ok, data = pcall(vim.json.decode, content)
  return ok and data or nil
end

local function cache_write(key, data)
  local f = io.open(cache_path(key), "w")
  if not f then
    return
  end
  f:write(vim.json.encode(data))
  f:close()
end

-- ============================================================
-- Async helpers
-- ============================================================

local function notify_error(message)
  vim.schedule(function()
    vim.notify(message, vim.log.levels.ERROR)
  end)
end

local function switch_to(path, label)
  vim.cmd("cd " .. vim.fn.fnameescape(path))
  vim.notify("Switched to " .. label)
end

-- jobstart wrapper that buffers stdout and calls back with a string (or nil on failure)
local function gh_async(args, callback)
  local stdout = {}
  local ok, _ = pcall(vim.fn.jobstart, args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(stdout, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      callback(code == 0 and table.concat(stdout, "\n") or nil)
    end,
  })
  if not ok then
    callback(nil)
  end
end

local function gh_json_async(args, callback)
  gh_async(args, function(text)
    if not text then
      return callback(nil)
    end
    local ok, decoded = pcall(vim.json.decode, text)
    callback(ok and decoded or nil)
  end)
end

local function gh_lines_async(args, callback)
  gh_async(args, function(text)
    if not text then
      return callback(nil)
    end
    local lines = {}
    for line in text:gmatch("[^\n]+") do
      table.insert(lines, line)
    end
    callback(lines)
  end)
end

-- Run N async jobs in parallel, callback once with array of their results
local function parallel(jobs, callback)
  local n = #jobs
  if n == 0 then
    return callback({})
  end
  local results = {}
  local remaining = n
  for i, job in ipairs(jobs) do
    job(function(result)
      results[i] = result
      remaining = remaining - 1
      if remaining == 0 then
        callback(results)
      end
    end)
  end
end

-- ============================================================
-- Live picker registry (so background refreshes can update open pickers)
-- ============================================================

local action_state = nil
local function get_action_state()
  if not action_state then
    action_state = require("telescope.actions.state")
  end
  return action_state
end

-- Map: cache_key -> { bufnr, make_finder }
local live_pickers = {}

local function register_live_picker(key, bufnr, make_finder)
  live_pickers[key] = { bufnr = bufnr, make_finder = make_finder }
end

local function unregister_live_picker(key)
  live_pickers[key] = nil
end

local function update_live_picker(key, items)
  local entry = live_pickers[key]
  if not entry then
    return
  end
  if not vim.api.nvim_buf_is_valid(entry.bufnr) then
    live_pickers[key] = nil
    return
  end
  local picker = get_action_state().get_current_picker(entry.bufnr)
  if not picker then
    return
  end
  picker:refresh(entry.make_finder(items), { reset_prompt = false })
end

-- ============================================================
-- Repo list refresh (parallel, deduped, cached)
-- ============================================================

local repo_refresh_in_flight = false
local repo_refresh_waiters = {}

local function flush_repo_waiters(items)
  local waiters = repo_refresh_waiters
  repo_refresh_waiters = {}
  for _, cb in ipairs(waiters) do
    vim.schedule(function()
      cb(items)
    end)
  end
end

local function refresh_repos(done)
  if done then
    table.insert(repo_refresh_waiters, done)
  end
  if repo_refresh_in_flight then
    return
  end
  repo_refresh_in_flight = true

  parallel({
    function(cb)
      gh_json_async({ "gh", "repo", "list", "--json", "nameWithOwner", "--limit", "200" }, cb)
    end,
    function(cb)
      gh_lines_async({ "gh", "api", "user/orgs", "--jq", ".[].login" }, cb)
    end,
  }, function(phase1)
    local my_repos = phase1[1]
    local orgs = phase1[2] or {}

    local org_list = {}
    local seen_org = {}
    for _, o in ipairs(orgs) do
      if o ~= "" and not seen_org[o] then
        seen_org[o] = true
        table.insert(org_list, o)
      end
    end
    for _, o in ipairs(extra_orgs) do
      if not seen_org[o] then
        seen_org[o] = true
        table.insert(org_list, o)
      end
    end

    local jobs = {}
    for _, org in ipairs(org_list) do
      table.insert(jobs, function(cb)
        gh_json_async({ "gh", "repo", "list", org, "--json", "nameWithOwner", "--limit", "200" }, cb)
      end)
    end

    parallel(jobs, function(phase2)
      local items = {}
      local seen = {}
      local function extend(repos)
        for _, repo in ipairs(repos or {}) do
          if repo.nameWithOwner and not seen[repo.nameWithOwner] then
            seen[repo.nameWithOwner] = true
            table.insert(items, {
              display = "  " .. repo.nameWithOwner,
              repo = repo.nameWithOwner,
              name = repo.nameWithOwner:match("/(.+)$"),
            })
          end
        end
      end
      extend(my_repos)
      for _, repos in ipairs(phase2) do
        extend(repos)
      end
      table.sort(items, function(a, b)
        return a.repo < b.repo
      end)

      if #items > 0 then
        cache_write("repos", items)
      end

      repo_refresh_in_flight = false
      vim.schedule(function()
        update_live_picker("repos", items)
      end)
      flush_repo_waiters(items)
    end)
  end)
end

-- ============================================================
-- Branches & PRs refresh (per repo, cached)
-- ============================================================

local branches_refresh_in_flight = {}
local branches_refresh_waiters = {}

local function refresh_branches_and_prs(repo_full, done)
  branches_refresh_waiters[repo_full] = branches_refresh_waiters[repo_full] or {}
  if done then
    table.insert(branches_refresh_waiters[repo_full], done)
  end
  if branches_refresh_in_flight[repo_full] then
    return
  end
  branches_refresh_in_flight[repo_full] = true

  parallel({
    function(cb)
      gh_lines_async({ "gh", "api", "repos/" .. repo_full .. "/branches", "--jq", ".[].name" }, cb)
    end,
    function(cb)
      gh_json_async({ "gh", "pr", "list", "--repo", repo_full, "--json", "number,title" }, cb)
    end,
  }, function(results)
    local branches = results[1] or {}
    local prs = results[2] or {}

    local items = {}
    for _, branch in ipairs(branches) do
      if branch ~= "" then
        table.insert(items, {
          display = "  " .. branch,
          type = "branch",
          value = branch,
          ordinal = "branch " .. branch,
        })
      end
    end
    for _, pr in ipairs(prs) do
      table.insert(items, {
        display = "  PR #" .. pr.number .. "  " .. pr.title,
        type = "pr",
        value = pr.number,
        ordinal = "pr " .. pr.title,
      })
    end

    if #items > 0 then
      cache_write("br_" .. repo_full, items)
    end

    branches_refresh_in_flight[repo_full] = nil
    vim.schedule(function()
      update_live_picker("br_" .. repo_full, items)
    end)

    local waiters = branches_refresh_waiters[repo_full] or {}
    branches_refresh_waiters[repo_full] = nil
    for _, cb in ipairs(waiters) do
      vim.schedule(function()
        cb(items)
      end)
    end
  end)
end

-- ============================================================
-- Worktree management (unchanged behavior)
-- ============================================================

local function find_existing_worktree(base_path, branch)
  local out = vim.fn.system({ "git", "-C", base_path, "worktree", "list", "--porcelain" })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local target = "branch refs/heads/" .. branch
  local current
  for line in out:gmatch("[^\n]+") do
    local p = line:match("^worktree (.+)$")
    if p then
      current = p
    elseif line == target then
      return current
    end
  end
  return nil
end

local function add_worktree(base_path, wt_path, branch, label)
  local existing = find_existing_worktree(base_path, branch)
  if existing then
    switch_to(existing, label)
    return
  end

  vim.notify("Fetching latest " .. branch .. "...")

  vim.fn.jobstart({ "git", "fetch", "origin", branch }, {
    cwd = base_path,
    on_exit = function(_, _)
      -- Force-reset local branch to origin tip and create worktree there.
      -- Safe because find_existing_worktree above guarantees branch isn't checked out anywhere.
      vim.fn.jobstart({ "git", "worktree", "add", "-B", branch, wt_path, "origin/" .. branch }, {
        cwd = base_path,
        on_exit = function(_, code)
          if code == 0 then
            vim.schedule(function()
              switch_to(wt_path, label)
            end)
            return
          end

          -- Fallback: origin/<branch> may not exist (local-only branch)
          vim.fn.jobstart({ "git", "worktree", "add", wt_path, branch }, {
            cwd = base_path,
            on_exit = function(_, c)
              if c == 0 then
                vim.schedule(function()
                  switch_to(wt_path, label)
                end)
              else
                notify_error("Worktree failed for: " .. branch)
              end
            end,
          })
        end,
      })
    end,
  })
end

local function add_pr_worktree(base_path, wt_path, pr_number, label)
  if vim.fn.isdirectory(wt_path) == 1 then
    switch_to(wt_path, label)
    return
  end

  vim.notify("Fetching PR #" .. pr_number .. "...")
  vim.fn.jobstart({ "git", "fetch", "origin", "refs/pull/" .. pr_number .. "/head" }, {
    cwd = base_path,
    on_exit = function(_, code)
      if code ~= 0 then
        notify_error("Failed to fetch PR #" .. pr_number)
        return
      end

      vim.fn.jobstart({ "git", "worktree", "add", wt_path, "FETCH_HEAD" }, {
        cwd = base_path,
        on_exit = function(_, c)
          if c == 0 then
            vim.schedule(function()
              switch_to(wt_path, label)
            end)
          else
            notify_error("Worktree failed for PR #" .. pr_number)
          end
        end,
      })
    end,
  })
end

local function open_as_worktree(repo_full, name, selection)
  local base_path = github_dir .. "/" .. name
  local branch = selection and tostring(selection.value) or "main"
  local slug = branch:gsub("[/\\#%s]", "-")
  local wt_path = selection and selection.type == "pr" and (github_dir .. "/" .. name .. "-pr-" .. branch)
    or (github_dir .. "/" .. name .. "-" .. slug)

  local function proceed()
    if selection and selection.type == "pr" then
      add_pr_worktree(base_path, wt_path, branch, name .. " PR #" .. branch)
    elseif vim.fn.isdirectory(wt_path) == 1 then
      switch_to(wt_path, name .. " @ " .. branch)
    else
      add_worktree(base_path, wt_path, branch, name .. " @ " .. branch)
    end
  end

  if vim.fn.isdirectory(base_path) == 0 then
    vim.notify("Cloning " .. repo_full .. "...")
    vim.fn.jobstart({ "gh", "repo", "clone", repo_full, base_path }, {
      on_exit = function(_, code)
        if code == 0 then
          vim.schedule(proceed)
        else
          notify_error("Clone failed")
        end
      end,
    })
  else
    proceed()
  end
end

-- ============================================================
-- Pickers
-- ============================================================

local function pick_branch_or_pr(repo_full, name)
  local cache_key = "br_" .. repo_full
  local cached = cache_read(cache_key) or {}

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local astate = get_action_state()

  local function make_finder(items)
    return finders.new_table({
      results = items,
      entry_maker = function(entry)
        return { value = entry, display = entry.display, ordinal = entry.ordinal }
      end,
    })
  end

  if #cached == 0 then
    vim.notify("Fetching branches and PRs for " .. name .. "...")
  end

  local picker = pickers.new({}, {
    prompt_title = name .. " — branches & PRs",
    finder = make_finder(cached),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      register_live_picker(cache_key, prompt_bufnr, make_finder)

      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = function()
          unregister_live_picker(cache_key)
        end,
      })

      actions.select_default:replace(function()
        local entry = astate.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then
          return
        end
        open_as_worktree(repo_full, name, entry.value)
      end)
      return true
    end,
  })
  picker:find()

  refresh_branches_and_prs(repo_full)
end

function M.pick()
  local cached = cache_read("repos") or {}

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local astate = get_action_state()

  local function make_finder(items)
    return finders.new_table({
      results = items,
      entry_maker = function(entry)
        return { value = entry, display = entry.display, ordinal = entry.repo }
      end,
    })
  end

  if #cached == 0 then
    vim.notify("Fetching repos...")
  end

  local picker = pickers.new({}, {
    prompt_title = "GitHub Repos",
    finder = make_finder(cached),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      register_live_picker("repos", prompt_bufnr, make_finder)

      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = function()
          unregister_live_picker("repos")
        end,
      })

      actions.select_default:replace(function()
        local entry = astate.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then
          return
        end
        pick_branch_or_pr(entry.value.repo, entry.value.name)
      end)
      return true
    end,
  })
  picker:find()

  refresh_repos()
end

-- ============================================================
-- Local-project pickers (unchanged)
-- ============================================================

local function open_local_picker(title, on_select)
  local actions = require("telescope.actions")
  local astate = get_action_state()

  require("telescope").extensions.repo.list({
    prompt_title = title,
    search_dirs = { github_dir },
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = astate.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          on_select(entry.value)
        end
      end)
      return true
    end,
  })
end

function M.pick_local()
  open_local_picker("Local Projects", function(path)
    switch_to(path, path)
  end)
end

function M.copy_path()
  open_local_picker("Copy Full Path", function(path)
    vim.fn.setreg("+", path)
    vim.notify("Copied: " .. path)
  end)
end

function M.open_in_finder()
  open_local_picker("Open in Finder", function(path)
    vim.fn.jobstart({ "open", path })
  end)
end

function M.open_in_github()
  local cwd = vim.fn.getcwd()
  local remote = vim.fn.system({ "git", "-C", cwd, "remote", "get-url", "origin" })
  if vim.v.shell_error ~= 0 then
    vim.notify("No directory opened", vim.log.levels.WARN)
    return
  end
  remote = remote:gsub("%s+$", "")
  local url = remote
    :gsub("^git@github%.com:", "https://github.com/")
    :gsub("%.git$", "")
  vim.fn.jobstart({ "open", url })
end

function M.git_diff()
  local cwd = vim.fn.getcwd()
  local out = vim.fn.system({ "git", "-C", cwd, "rev-parse", "--git-dir" })
  if vim.v.shell_error ~= 0 then
    vim.notify("No directory opened", vim.log.levels.WARN)
    return
  end
  vim.cmd("DiffviewOpen")
end

-- ============================================================
-- Worktree picker for current repo (unchanged)
-- ============================================================

function M.worktrees()
  local cwd = vim.fn.getcwd()
  local out = vim.fn.system({ "git", "-C", cwd, "worktree", "list", "--porcelain" })
  if vim.v.shell_error ~= 0 or out == "" then
    vim.notify("Not in a git repo", vim.log.levels.WARN)
    return
  end

  local items = {}
  local path, branch
  local function add_item()
    if not path then
      return
    end
    table.insert(
      items,
      { display = (branch or "detached") .. "  " .. path, path = path, branch = branch or "detached" }
    )
    path, branch = nil, nil
  end

  for line in out:gmatch("[^\n]+") do
    local wt = line:match("^worktree (.+)$")
    if wt then
      add_item()
      path = wt
    elseif line:match("^branch ") then
      branch = line:gsub("^branch refs/heads/", "")
    elseif line == "detached" then
      branch = "detached"
    end
  end
  add_item()

  if #items == 0 then
    vim.notify("No worktrees found", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local astate = get_action_state()

  pickers
    .new({}, {
      prompt_title = "Worktrees",
      finder = finders.new_table({
        results = items,
        entry_maker = function(entry)
          return { value = entry, display = entry.display, ordinal = entry.display }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = astate.get_selected_entry()
          actions.close(prompt_bufnr)
          if not entry then
            return
          end
          switch_to(entry.value.path, entry.value.branch)
        end)
        return true
      end,
    })
    :find()
end

-- ============================================================
-- Linear todos
-- ============================================================

local function linear_gql_async(query, variables, callback)
  vim.defer_fn(function()
    local request_tmp = os.tmpname()
    local request_file = io.open(request_tmp, "w")
    if not request_file then
      callback(nil, "cannot write temp request file")
      return
    end
    request_file:write(vim.json.encode({ query = query, variables = variables }))
    request_file:close()

    local script_tmp = os.tmpname() .. ".py"
    local script_file = io.open(script_tmp, "w")
    if not script_file then
      os.remove(request_tmp)
      callback(nil, "cannot write temp python script")
      return
    end

    script_file:write(string.format([=[
import json
import os
import sys
import urllib.error
import urllib.request

ENV_PATH = os.path.expanduser("~/.claude/skills/linear/.env")
REQUEST_PATH = %q


def fail(message):
    print("ERROR:" + str(message).replace("\n", " ").replace("\r", " "))
    sys.exit(0)


def clean(value):
    if value is None:
        return ""
    return str(value).replace("|", " ").replace("\n", " ").replace("\r", " ")


api_key = None
try:
    with open(ENV_PATH, "r", encoding="utf-8") as env_file:
        for line in env_file:
            if line.startswith("LINEAR_API_KEY="):
                api_key = line.split("=", 1)[1].strip()
                break
except OSError as exc:
    fail("LINEAR_API_KEY not found: " + str(exc))

if not api_key:
    fail("LINEAR_API_KEY not found")

try:
    with open(REQUEST_PATH, "rb") as request_file:
        body = request_file.read()
except OSError as exc:
    fail("cannot read request: " + str(exc))

request = urllib.request.Request(
    "https://api.linear.app/graphql",
    data=body,
    headers={
        "Authorization": api_key,
        "Content-Type": "application/json",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = json.loads(response.read().decode("utf-8"))
except urllib.error.HTTPError as exc:
    detail = exc.read().decode("utf-8", errors="replace")
    fail("Linear HTTP " + str(exc.code) + ": " + detail[:200])
except Exception as exc:
    fail(str(exc))

if payload.get("errors"):
    first = payload["errors"][0]
    fail(first.get("message", first))

nodes = (((payload.get("data") or {}).get("issues") or {}).get("nodes") or [])
for issue in nodes:
    state = issue.get("state") or {}
    project = issue.get("project")
    print("|".join([
        clean(issue.get("identifier")),
        clean(issue.get("title")),
        clean(issue.get("url")),
        clean(issue.get("priority")),
        clean(state.get("name")),
        clean(project.get("name")) if project else "__NONE__",
    ]))
]=], request_tmp))
    script_file:close()

    local raw = vim.fn.system({ "python3", script_tmp })
    local shell_error = vim.v.shell_error
    os.remove(script_tmp)
    os.remove(request_tmp)

    if shell_error ~= 0 then
      callback(nil, "python failed (exit " .. shell_error .. ")")
      return
    end

    local nodes = {}
    for line in raw:gmatch("[^\r\n]+") do
      if line:sub(1, 6) == "ERROR:" then
        callback(nil, line:sub(7))
        return
      end

      local fields = vim.split(line, "|", { plain = true })
      if #fields >= 6 then
        local project = fields[6] ~= "__NONE__" and { name = fields[6] } or nil
        table.insert(nodes, {
          identifier = fields[1],
          title = fields[2],
          url = fields[3],
          priority = tonumber(fields[4]) or 0,
          state = { name = fields[5] },
          project = project,
        })
      end
    end

    callback({ data = { issues = { nodes = nodes } } }, nil)
  end, 0)
end

function M.linear_todos()
  vim.notify("Fetching Linear todos…")

  local query = [[
    query($id: ID!) {
      issues(
        filter: {
          assignee: { id: { eq: $id } }
          state: { type: { nin: ["completed", "cancelled"] } }
        }
        first: 50
        orderBy: updatedAt
      ) {
        nodes { identifier title url priority state { name } project { name } }
      }
    }
  ]]

  linear_gql_async(query, { id = "a3fd8099-5265-4f48-a3f8-639c70709b0d" }, function(data, err)
    if err or not data then
      vim.schedule(function() notify_error("Linear: " .. (err or "unknown error")) end)
      return
    end

    local nodes = (((data.data or {}).issues) or {}).nodes or {}
    if #nodes == 0 then
      vim.schedule(function() vim.notify("No pending todos!") end)
      return
    end

    local prio_icon = { [0] = "·", [1] = "!", [2] = "↑", [3] = "→", [4] = "↓" }

    local items = {}
    for _, issue in ipairs(nodes) do
      local p   = prio_icon[issue.priority] or "·"
      local proj = issue.project and ("  " .. issue.project.name) or ""
      local state = issue.state and issue.state.name or "?"
      items[#items + 1] = {
        display  = p .. "  " .. issue.identifier .. "  " .. issue.title .. proj .. "  (" .. state .. ")",
        ordinal  = issue.identifier .. " " .. issue.title,
        url      = issue.url,
        id       = issue.identifier,
      }
    end

    vim.schedule(function()
      local pickers = require("telescope.pickers")
      local finders = require("telescope.finders")
      local conf    = require("telescope.config").values
      local actions = require("telescope.actions")
      local astate  = get_action_state()

      pickers.new({}, {
        prompt_title = "My Linear Todos (" .. #items .. ")",
        finder = finders.new_table({
          results = items,
          entry_maker = function(e)
            return { value = e, display = e.display, ordinal = e.ordinal }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local entry = astate.get_selected_entry()
            actions.close(prompt_bufnr)
            if not entry then return end
            vim.fn.jobstart({ "open", entry.value.url })
            vim.notify("Opening " .. entry.value.id)
          end)
          return true
        end,
      }):find()
    end)
  end)
end

-- ============================================================
-- Auto-sync: warm cache on startup, then refresh every AUTO_REFRESH_MS
-- ============================================================

local timer = (vim.uv or vim.loop).new_timer()
if timer then
  timer:start(
    2000,
    AUTO_REFRESH_MS,
    vim.schedule_wrap(function()
      refresh_repos()
    end))
end

return M
