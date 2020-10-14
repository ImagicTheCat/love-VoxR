-- Basic file based SVO world implementation.

local SAVE_DIR = love.filesystem.getSaveDirectory()
local world = {levels = 17}
-- open data files
local init = (not love.filesystem.getInfo("world.alloc") or not love.filesystem.getInfo("world.blocks"))
if init then
  love.filesystem.write("world.alloc", love.data.pack("string", ">I4I4", 1, 0)) -- init used blocks / available stack size
  love.filesystem.write("world.blocks", string.rep("\0", 12)) -- root block
end
world.f_alloc = io.open(SAVE_DIR.."/world.alloc", "r+b")
world.f_blocks = io.open(SAVE_DIR.."/world.blocks", "r+b")
-- read header data
world.used_blocks, world.available_cblocks = love.data.unpack(">I4I4", world.f_alloc:read(8))

-- METHODS

local function allocateCBlock(self)
  local cindex
  if self.available_cblocks > 0 then
    -- update available cblocks
    self.available_cblocks = self.available_cblocks-1
    self.f_alloc:seek("set", 4)
    self.f_alloc:write(love.data.pack("string", ">I4", self.available_cblocks))
    -- fetch index
    self.f_alloc:seek("set", 8+self.available_cblocks*4)
    cindex = love.data.unpack(">I4", self.f_alloc:read(4))
  else -- append block
    cindex = self.used_blocks
    self.used_blocks = self.used_blocks+8
    self.f_alloc:seek("set", 0)
    self.f_alloc:write(love.data.pack("string", ">I4", self.used_blocks))
  end
  -- fill with zero
  self.f_blocks:seek("set", cindex*12)
  self.f_blocks:write(string.rep("\0", 12*8))
  return cindex
end

-- recursive
local function freeCBlock(self, cindex)
  -- write new available index
  self.f_alloc:seek("set", 8+self.available_cblocks*4)
  self.f_alloc:write(love.data.pack("string", ">I4", cindex))
  -- update count
  self.available_cblocks = self.available_cblocks+1
  self.f_alloc:seek("set", 4)
  self.f_alloc:write(love.data.pack("string", ">I4", self.available_cblocks))
  -- recursive
  for i=cindex, cindex+7 do
    self.f_blocks:seek("set", i*12+8)
    local sub_cindex = love.data.unpack(">I4", self.f_blocks:read(4))
    if sub_cindex ~= 0 then freeCBlock(self, sub_cindex) end
  end
end

-- state: fill data
-- index: block index
-- x,y,z: block origin in SVO-voxels coordinates
-- size: block size (voxels)
local function recursive_fill(self, state, index, x, y, z, size)
  --print("SVO fill", index, x, y, z, size)
  -- compute intersection between block area and fill area
  local x1, x2 = math.max(state.x1, x), math.min(state.x2, x+size)
  local y1, y2 = math.max(state.y1, y), math.min(state.y2, y+size)
  local z1, z2 = math.max(state.z1, z), math.min(state.z2, z+size)

  if x1 == x and y1 == y and z1 == z --
    and x2 == x+size and y2 == y+size and z2 == z+size then -- full
    -- set block data
    if state.metalness then
      self.f_blocks:seek("set", index*12)
      self.f_blocks:write(love.data.pack("string", "BBBBBBBB",
        state.metalness, state.roughness, state.emission, 0x01,
        state.r, state.g, state.b, 0
      ))
    else -- empty
      self.f_blocks:seek("set", index*12+3)
      self.f_blocks:write(love.data.pack("string", "B", 0))
    end
    -- free children
    self.f_blocks:seek("set", index*12+8)
    local cindex = love.data.unpack(">I4", self.f_blocks:read(4))
    if cindex ~= 0 then
      -- reset cindex
      self.f_blocks:seek("cur", -4)
      self.f_blocks:write(love.data.pack("string", ">I4", 0))
      freeCBlock(self, cindex)
    end
  elseif x1 < x2 and y1 < y2 and z1 < z2 then -- partial (recursion)
    -- get/create children blocks
    self.f_blocks:seek("set", index*12+8)
    local cindex = love.data.unpack(">I4", self.f_blocks:read(4))
    if cindex == 0 then
      cindex = allocateCBlock(self)
      self.f_blocks:seek("set", index*12+8)
      self.f_blocks:write(love.data.pack("string", ">I4", cindex))
    end
    local ssize = size/2
    recursive_fill(self, state, cindex, x, y, z, ssize)
    recursive_fill(self, state, cindex+1, x, y, z+ssize, ssize)
    recursive_fill(self, state, cindex+2, x, y+ssize, z, ssize)
    recursive_fill(self, state, cindex+3, x, y+ssize, z+ssize, ssize)
    recursive_fill(self, state, cindex+4, x+ssize, y, z, ssize)
    recursive_fill(self, state, cindex+5, x+ssize, y, z+ssize, ssize)
    recursive_fill(self, state, cindex+6, x+ssize, y+ssize, z, ssize)
    recursive_fill(self, state, cindex+7, x+ssize, y+ssize, z+ssize, ssize)
    -- TODO: aggregate
  end
end

-- Fill the SVO with a voxel area.
-- x1, y1, z1, x2, y2, z2: area boundaries
-- metalness, roughness, emission, r, g, b: (optional) voxel data (nothing = empty voxels)
function world:fill(x1, y1, z1, x2, y2, z2, metalness, roughness, emission, r, g, b)
  local state = {
    x1 = x1, y1 = y1, z1 = z1,
    x2 = x2, y2 = y2, z2 = z2,
    metalness = metalness,
    roughness = roughness,
    emission = emission,
    r = r, g = g, b = b
  }
  local size = 2^(self.levels-1)
  recursive_fill(self, state, 0, -size/2, -size/2, -size/2, size)
end

world:fill(0,0,0, 300,10,10, 0,125,0, 255,0,0)
--world:fill(0,0,0, 10,10,10, 0,125,0, 255,0,0)
world:fill(-300,-300,-300, 300,300,300)

return world
