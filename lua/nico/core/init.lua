vim.env.PATH = "C:/Program Files/nodejs;" .. vim.env.PATH
vim.env.PATHEXT = ".COM;.EXE;.BAT;.CMD"
require("nico.core.options")
require("nico.core.keymaps")
require("nico.core.godot").setup()
require("nico.tools").setup()
