local M = {}

local github_dir = vim.fn.expand("~/Documents/GitHub")

local function switch_to(path, label)
  vim.cmd("cd " .. path)
  vim.notify("Switched to " .. label)
end

local function find_existing_worktree(base_path, branch)
  local out = vim.fn.system({ "git", "-C", base_path, "worktree", "list", "--porcelain" })
  if vim.v.shell_error ~= 0 then return nil end
  local target = "branch refs/heads/" .. branch
  local current
  for line in out:gmatch("[^\n]+") do
    local p = line:match("^worktree (.+)$")
    if p then current = p
    elseif line == target then return current end
  end
  return nil
end

local function add_worktree(base_path, wt_path, branch, label)
  local existing = find_existing_worktree(base_path, branch)
  if existing then
    switch_to(existing, label)
    return
  end

  vim.fn.jobstart({ "git", "worktree", "add", wt_path, branch }, {
    cwd = base_path,
    on_exit = function(_, code)
      if code == 0 then
        vim.schedule(function() switch_to(wt_path, label) end)
      else
        vim.fn.jobstart({ "git", "worktree", "add", "--track", "-b", branch, wt_path, "origin/" .. branch }, {
          cwd = base_path,
          on_exit = function(_, c)
            vim.schedule(function()
              if c == 0 then switch_to(wt_path, label)
              else vim.notify("Worktree failed for: " .. branch, vim.log.levels.ERROR) end
            end)
          end,
        })
      end
    end,
  })
end

local function open_as_worktree(repo_full, name, selection)
  local base_path = github_dir .. "/" .. name
  local branch = selection and tostring(selection.value) or "main"
  local slug = branch:gsub("[/\\#%s]", "-")
  local wt_path = selection and selection.type == "pr"
    and (github_dir .. "/" .. name .. "-pr-" .. branch)
    or  (github_dir .. "/" .. name .. "-" .. slug)

  local function proceed()
    if selection and selection.type == "pr" then
      vim.notify("Fetching PR #" .. branch .. "...")
      local info_raw = vim.fn.system("gh pr view " .. branch .. " --repo " .. repo_full .. " --json headRefName 2>/dev/null")
      local ok, info = pcall(vim.json.decode, info_raw)
      if not ok or not info then
        vim.notify("Failed to get PR info", vim.log.levels.ERROR)
        return
      end
      local pr_branch = info.headRefName
      vim.fn.jobstart({ "git", "fetch", "origin", pr_branch }, {
        cwd = base_path,
        on_exit = function(_, code)
          if code == 0 then
            vim.schedule(function()
              if vim.fn.isdirectory(wt_path) == 1 then
                switch_to(wt_path, name .. " PR #" .. branch)
              else
                add_worktree(base_path, wt_path, pr_branch, name .. " PR #" .. branch)
              end
            end)
          else
            vim.schedule(function() vim.notify("Failed to fetch PR branch", vim.log.levels.ERROR) end)
          end
        end,
      })
    else
      if vim.fn.isdirectory(wt_path) == 1 then
        switch_to(wt_path, name .. " @ " .. branch)
      else
        add_worktree(base_path, wt_path, branch, name .. " @ " .. branch)
      end
    end
  end

  if vim.fn.isdirectory(base_path) == 0 then
    vim.notify("Cloning " .. repo_full .. "...")
    vim.fn.jobstart({ "gh", "repo", "clone", repo_full, base_path }, {
      on_exit = function(_, code)
        if code == 0 then vim.schedule(proceed)
        else vim.schedule(function() vim.notify("Clone failed", vim.log.levels.ERROR) end) end
      end,
    })
  else
    proceed()
  end
end

local function pick_branch_or_pr(repo_full, name)
  vim.notify("Fetching branches and PRs...")

  local branches_out = vim.fn.system("gh api repos/" .. repo_full .. "/branches --jq '.[].name' 2>/dev/null")
  local prs_out = vim.fn.system("gh pr list --repo " .. repo_full .. " --json number,title 2>/dev/null")

  local items = {}

  for branch in branches_out:gmatch("[^\n]+") do
    if branch ~= "" then
      table.insert(items, { display = "  " .. branch, type = "branch", value = branch, ordinal = "branch " .. branch })
    end
  end

  local ok, prs = pcall(vim.json.decode, prs_out)
  if ok and prs then
    for _, pr in ipairs(prs) do
      table.insert(items, {
        display = "  PR #" .. pr.number .. "  " .. pr.title,
        type = "pr",
        value = pr.number,
        ordinal = "pr " .. pr.title,
      })
    end
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = name .. " — branches & PRs",
    finder = finders.new_table({
      results = items,
      entry_maker = function(entry)
        return { value = entry, display = entry.display, ordinal = entry.ordinal }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local sel = action_state.get_selected_entry().value
        open_as_worktree(repo_full, name, sel)
      end)
      return true
    end,
  }):find()
end

local github_dir_expanded = vim.fn.expand("~/Documents/GitHub")

local function open_local_picker(title, on_select)
  local actions     = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  require("telescope").extensions.repo.list({
    prompt_title   = title,
    search_dirs    = { github_dir_expanded },
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry then on_select(entry.value) end
      end)
      return true
    end,
  })
end

function M.pick_local()
  open_local_picker("Local Projects", function(path)
    vim.cmd("cd " .. vim.fn.fnameescape(path))
    vim.notify("Switched to " .. path)
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

function M.git_diff()
  open_local_picker("Git Diff", function(path)
    vim.cmd("cd " .. vim.fn.fnameescape(path))
    vim.cmd("DiffviewOpen")
  end)
end

function M.pick()
  local cmd = "{ gh repo list --json nameWithOwner --limit 200; for org in $(gh api user/orgs --jq '.[].login' 2>/dev/null); do gh repo list \"$org\" --json nameWithOwner --limit 200 2>/dev/null; done; } 2>/dev/null | jq -s 'add | unique_by(.nameWithOwner)'"
  local handle = io.popen(cmd)
  if not handle then
    vim.notify("gh CLI not available", vim.log.levels.ERROR)
    return
  end
  local result = handle:read("*a")
  handle:close()

  local ok, repos = pcall(vim.json.decode, result)
  if not ok or not repos then
    vim.notify("Failed to fetch repos. Run: gh auth login", vim.log.levels.ERROR)
    return
  end

  local items = {}
  for _, repo in ipairs(repos) do
    local name = repo.nameWithOwner:match("/(.+)$")
    local cloned = vim.fn.isdirectory(github_dir .. "/" .. name) == 1
    table.insert(items, {
      display = (cloned and "  " or "  ") .. repo.nameWithOwner,
      repo = repo.nameWithOwner,
      name = name,
    })
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "GitHub Repos",
    finder = finders.new_table({
      results = items,
      entry_maker = function(entry)
        return { value = entry, display = entry.display, ordinal = entry.repo }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry().value
        pick_branch_or_pr(entry.repo, entry.name)
      end)
      return true
    end,
  }):find()
end

-- List all active worktrees for the current repo
function M.worktrees()
  local cwd = vim.fn.getcwd()
  local out = vim.fn.system("git -C " .. cwd .. " worktree list --porcelain 2>/dev/null")
  if out == "" then
    vim.notify("Not in a git repo", vim.log.levels.WARN)
    return
  end

  local items = {}
  local path, branch
  for line in out:gmatch("[^\n]+") do
    if line:match("^worktree ") then
      path = line:gsub("^worktree ", "")
    elseif line:match("^branch ") then
      branch = line:gsub("^branch refs/heads/", "")
    elseif line == "" and path then
      table.insert(items, { display = (branch or "detached") .. "  " .. path, path = path, branch = branch or "" })
      path, branch = nil, nil
    end
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
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
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry().value
        switch_to(entry.path, entry.branch)
      end)
      return true
    end,
  }):find()
end

return M
