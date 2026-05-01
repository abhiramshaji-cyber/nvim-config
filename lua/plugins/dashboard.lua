return {
  "folke/snacks.nvim",
  keys = {
    {
      "<leader>h",
      function()
        require("snacks").dashboard()
      end,
      desc = "Home",
    },
  },
  opts = {
    picker = {
      sources = {
        explorer = {
          win = {
            list = {
              keys = {
                ["n"] = function(_win)
                  local pickers = Snacks.picker.get({ source = "explorer" })
                  local picker = pickers and pickers[1]
                  if not picker then return end
                  local item = picker:current()
                  if not item then return end
                  local dir = item.dir and item.file or vim.fn.fnamemodify(item.file, ":h")
                  vim.fn.jobstart({
                    "osascript",
                    "-e", 'tell application "Ghostty" to activate',
                    "-e", "delay 0.2",
                    "-e", 'tell application "System Events"',
                    "-e", '  tell process "ghostty"',
                    "-e", '    keystroke "t" using {command down}',
                    "-e", "    delay 0.3",
                    "-e", '    keystroke "cd " & quote & "' .. dir .. '" & quote',
                    "-e", "    keystroke return",
                    "-e", "  end tell",
                    "-e", "end tell",
                  })
                end,
                ["w"] = function(_win)
                  local pickers = Snacks.picker.get({ source = "explorer" })
                  local picker = pickers and pickers[1]
                  if not picker then return end
                  local item = picker:current()
                  if not item then return end
                  local dir = item.dir and item.file or vim.fn.fnamemodify(item.file, ":h")
                  vim.fn.jobstart({
                    "osascript",
                    "-e", 'tell application "Ghostty" to activate',
                    "-e", "delay 0.2",
                    "-e", 'tell application "System Events"',
                    "-e", '  tell process "ghostty"',
                    "-e", '    keystroke "n" using {command down}',
                    "-e", "    delay 0.8",
                    "-e", '    keystroke "cd " & quote & "' .. dir .. '" & quote',
                    "-e", "    keystroke return",
                    "-e", "  end tell",
                    "-e", "end tell",
                  })
                end,
                ["t"] = function(_win)
                  local pickers = Snacks.picker.get({ source = "explorer" })
                  local picker = pickers and pickers[1]
                  if not picker then return end
                  local item = picker:current()
                  if not item then return end
                  local dir = item.dir and item.file or vim.fn.fnamemodify(item.file, ":h")
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
                        if code ~= 0 then
                          vim.notify("osascript failed (code " .. code .. ") — check Accessibility permissions for Ghostty", vim.log.levels.ERROR)
                        end
                      end)
                    end,
                    on_stderr = function(_, data)
                      if data and data[1] ~= "" then
                        vim.schedule(function()
                          vim.notify(table.concat(data, "\n"), vim.log.levels.ERROR)
                        end)
                      end
                    end,
                  })
                end,
              },
            },
          },
        },
      },
    },
    dashboard = {
      preset = {
        header = table.concat({
          "██████╗ ███████╗██╗     ██╗██╗   ██╗███████╗██████╗ ██╗   ██╗",
          "██╔══██╗██╔════╝██║     ██║██║   ██║██╔════╝██╔══██╗╚██╗ ██╔╝",
          "██║  ██║█████╗  ██║     ██║██║   ██║█████╗  ██████╔╝ ╚████╔╝ ",
          "██║  ██║██╔══╝  ██║     ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗  ╚██╔╝  ",
          "██████╔╝███████╗███████╗██║ ╚████╔╝ ███████╗██║  ██║   ██║   ",
          "╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝   ╚═╝   ",
        }, "\n"),
        keys = {
          { icon = " ", key = "g", desc = "GitHub Repos", action = ":lua require('gh').pick()" },
          { icon = " ", key = "e", desc = "Open in Finder", action = ":lua require('gh').open_in_finder()" },
          { icon = " ", key = "o", desc = "Open in GitHub", action = ":lua require('gh').open_in_github()" },
          { icon = " ", key = "t", desc = "My Todos", action = ":lua require('gh').linear_todos()" },
          { icon = " ", key = "d", desc = "Git Diff", action = ":lua require('gh').git_diff()" },
          { icon = " ", key = "q", desc = "Quit", action = ":qa" },
        },
      },
    },
  },
}
