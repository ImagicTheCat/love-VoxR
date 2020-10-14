-- Basic file based SVO world implementation.

local SAVE_DIR = love.filesystem.getSaveDirectory()
local world = {}
-- open data files
if not love.filesystem.getInfo("world.meta") then
  love.filesystem.write("world.meta", love.data.pack("string", ">I4I4", 1, 0)) -- init used blocks / available stack size
end
world.f_meta = io.open(SAVE_DIR.."/world.meta", "r+")
if not love.filesystem.getInfo("world.blocks") then
  love.filesystem.write("world.blocks", string.rep("\0", 12)) -- root block
end
world.f_blocks = io.open(SAVE_DIR.."/world.blocks", "r+")
-- read used blocks
world.used_blocks = love.data.unpack(">I4", world.f_meta:read(4))

return world
