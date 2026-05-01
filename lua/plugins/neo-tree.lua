return {
  "nvim-neo-tree/neo-tree.nvim",
  keys = {
    { "<C-b>", "<cmd>Neotree toggle<cr>", desc = "Toggle Neo-tree" },
  },
  opts = {
    window = {
      mappings = {
        Y = function(state)
          local node = state.tree:get_node()
          local path = node:get_id()
          vim.fn.setreg("+", path)
          vim.notify("Copied: " .. path, vim.log.levels.INFO)
        end,
        -- T to test without any default conflict
        T = function(state)
          vim.cmd("echomsg 'T fired!'")
        end,
        t = function(state)
          local node = state.tree:get_node()
          local path = node:get_id()
          local dir = vim.fn.isdirectory(path) == 1 and path or vim.fn.fnamemodify(path, ":h")
          vim.cmd("echomsg 't fired: " .. dir .. "'")
          vim.fn.jobstart({
            "osascript",
            "-e", 'tell application "Ghostty" to activate',
            "-e", "delay 0.2",
            "-e", 'tell application "System Events"',
            "-e", '  tell process "ghostty"',
            "-e", '    keystroke "d" using {command down}',
            "-e", "    delay 0.3",
            "-e", '    keystroke "cd " & quote & "' .. dir .. '" & quote',
            "-e", "    keystroke return",
            "-e", "  end tell",
            "-e", "end tell",
          }, {
            on_exit = function(_, code)
              vim.schedule(function()
                vim.cmd("echomsg 'osascript exit: " .. code .. "'")
              end)
            end,
            on_stderr = function(_, data)
              if data and data[1] ~= "" then
                vim.schedule(function()
                  vim.cmd("echomsg 'osascript err: " .. vim.inspect(data) .. "'")
                end)
              end
            end,
          })
        end,
      },
    },
  },
}
