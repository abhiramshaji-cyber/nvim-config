return {
  "folke/snacks.nvim",
  opts = {
    dashboard = {
      preset = {
        keys = {
          { icon = " ", key = "p", desc = "Local Projects",  action = ":lua require('telescope').extensions.repo.list({ search_dirs = { '~/Documents/GitHub' } })" },
          { icon = " ", key = "g", desc = "GitHub Repos",    action = ":lua require('gh').pick()" },
          { icon = " ", key = "q", desc = "Quit",            action = ":qa" },
        },
      },
    },
  },
}
