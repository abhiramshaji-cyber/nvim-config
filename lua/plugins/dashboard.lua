return {
  "folke/snacks.nvim",
  opts = {
    dashboard = {
      preset = {
        header = [[
    ____  __
   / __ \/ /_  ______ _
  / /_/ / / / / / __ `/
 / ____/ / /_/ / /_/ /
/_/   /_/\__,_/\__, /
              /____/

    ___              ______
   /   |  ____  ____/ / __ \_________ ___  __
  / /| | / __ \/ __  / /_/ / ___/ __ `/ / / /
 / ___ |/ / / / /_/ / ____/ /  / /_/ / /_/ /
/_/  |_/_/ /_/\__,_/_/   /_/   \__,_/\__, /
                                    /____/]],
        keys = {
          { icon = " ", key = "p", desc = "Local Projects",  action = ":lua require('telescope').extensions.repo.list({ search_dirs = { '~/Documents/GitHub' } })" },
          { icon = " ", key = "g", desc = "GitHub Repos",    action = ":lua require('gh').pick()" },
          { icon = " ", key = "q", desc = "Quit",            action = ":qa" },
        },
      },
    },
  },
}
