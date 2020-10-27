-- Basic file based SVO world implementation.
local bit = require("bit")
local ffi = require("ffi")
local VoxR = require("love-VoxR")

local SAVE_DIR = love.filesystem.getSaveDirectory()
local world = {levels = 17, unit = 0.125}
world.view_tree = {}
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

function world:setSVO(svo)
  self.svo = svo
  self.f_blocks:seek("set", 0)
  local data = self.f_blocks:read("*a")
  svo:updateTree(ffi.cast("const uint8_t*", data))
end

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
--  print("SVO fill", index, x, y, z, size)
  -- compute intersection between block area and fill area
  local x1, x2 = math.max(state.x1, x), math.min(state.x2, x+size)
  local y1, y2 = math.max(state.y1, y), math.min(state.y2, y+size)
  local z1, z2 = math.max(state.z1, z), math.min(state.z2, z+size)

  if x1 == x and y1 == y and z1 == z --
    and x2 == x+size and y2 == y+size and z2 == z+size then -- full
    -- set block data
    self.f_blocks:seek("set", index*12)
    self.f_blocks:write(state.write_data)
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
    self.f_blocks:seek("set", index*12)
    local block_data = self.f_blocks:read(8)
    local cindex = love.data.unpack(">I4", self.f_blocks:read(4))
    -- subdivide if write data is different than leaf data
    if cindex == 0 and block_data ~= state.write_data then
      cindex = allocateCBlock(self)
      self.f_blocks:seek("set", index*12+8)
      self.f_blocks:write(love.data.pack("string", ">I4", cindex))
    end
    if cindex ~= 0 then
      local ssize = size/2
      recursive_fill(self, state, cindex, x, y, z, ssize)
      recursive_fill(self, state, cindex+1, x, y, z+ssize, ssize)
      recursive_fill(self, state, cindex+2, x, y+ssize, z, ssize)
      recursive_fill(self, state, cindex+3, x, y+ssize, z+ssize, ssize)
      recursive_fill(self, state, cindex+4, x+ssize, y, z, ssize)
      recursive_fill(self, state, cindex+5, x+ssize, y, z+ssize, ssize)
      recursive_fill(self, state, cindex+6, x+ssize, y+ssize, z, ssize)
      recursive_fill(self, state, cindex+7, x+ssize, y+ssize, z+ssize, ssize)
      -- aggregate
      self.f_blocks:seek("set", cindex*12)
      local children_data = self.f_blocks:read(12*8)
      if children_data == string.rep(children_data:sub(1, 12), 8) then -- identical children, make leaf
        self.f_blocks:seek("set", index*12)
        self.f_blocks:write(children_data:sub(1, 8))
        self.f_blocks:write(love.data.pack("string", ">I4", 0))
        freeCBlock(self, cindex)
      else -- compute aggregate
        local t_metalness, t_roughness, t_emission, t_r, t_g, t_b, t_a = 0,0,0,0,0,0,0,0
        local full_count = 0
        for i=0,7 do
          local metalness, roughness, emission, flags, r, g, b, a = love.data.unpack("BBBBBBBB", children_data:sub(i*12+1, i*12+8))
          if bit.band(flags, 0x01) ~= 0 then
            full_count = full_count+1
            t_metalness = t_metalness+metalness
            t_roughness = t_roughness+roughness
            t_emission = t_emission+emission
            t_r = t_r+r; t_g = t_g+g; t_b = t_b+b; t_a = t_a+a
          end
        end
        t_metalness = math.floor(t_metalness/8)
        t_roughness = math.floor(t_roughness/8)
        t_emission = math.floor(t_emission/8) -- TODO: non-linear mean fix
        t_r = math.floor(t_r/8)
        t_g = math.floor(t_g/8)
        t_b = math.floor(t_b/8)
        t_a = math.floor(t_a/8)
        self.f_blocks:seek("set", index*12)
        self.f_blocks:write(love.data.pack("string", "BBBBBBBB",
          t_metalness, t_roughness, t_emission, full_count >= 4 and 0x01 or 0x00,
          t_r, t_g, t_b, t_a
        ))
      end
    end
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
  if state.metalness then
    state.write_data = love.data.pack("string", "BBBBBBBB",
      state.metalness, state.roughness, state.emission, 0x01,
      state.r, state.g, state.b, 0)
  else
    state.write_data = string.rep("\0", 8)
  end
  local size = 2^(self.levels-1)
  recursive_fill(self, state, 0, -size/2, -size/2, -size/2, size)
end

-- Add/remove level of details by building a sparse update SVO based on the
-- current view tree while updating it.
--
-- x,y,z,size: block position/size (meters)
-- wi: world block index
-- vi: update-view buffer block index
-- pvnode: parent view tree node
-- ci: child index (from parent)
-- lvl: recursion level
local function recursive_update_view(self, state, wi, vi, pvnode, ci, lvl, x, y, z, size)
  -- compute distance between block (center) and view
  local dx, dy, dz = x+size/2-state.x, y+size/2-state.y, z+size/2-state.z
  local dist = math.sqrt(dx*dx+dy*dy+dz*dz)
  -- compute required LOD
  local lod = self.levels-1-(dist > state.min_dist and math.floor(math.log(dist-state.min_dist+1)/math.log(2)) or 0)
  local vnode = pvnode and pvnode[ci]
  if vnode and vnode.full then return end -- sub-tree is already loaded
  print("block", wi, vi, ci, x, y, z, size, dist, lod)
  -- read world block
  self.f_blocks:seek("set", wi*12)
  local block_data = self.f_blocks:read(8)
  local w_cindex = love.data.unpack(">I4", self.f_blocks:read(4))
  if w_cindex ~= 0 then -- recursion
    -- allocate update-view buffer children
    if state.allocated-state.used < 8 then
      -- not enough memory, double allocated blocks
      local old_allocated = state.allocated
      local old_buffer = state.buffer
      state.allocated = state.allocated*2
      state.buffer = love.data.newByteData(state.allocated*12)
      state.p_buffer = ffi.cast("uint8_t*", state.buffer:getFFIPointer())
      ffi.copy(state.p_buffer, old_buffer:getFFIPointer(), old_allocated*12)
      old_buffer:release()
    end
    local v_cindex = state.used
    state.used = state.used+8
    VoxR.block_cindex(state.p_buffer+vi*12, v_cindex)
    -- do recursion
    local ssize = size/2
    recursive_update_view(self, state, w_cindex, v_cindex, vnode, 0, lvl+1, x, y, z, ssize)
    recursive_update_view(self, state, w_cindex+1, v_cindex+1, vnode, 1, lvl+1, x, y, z+ssize, ssize)
    recursive_update_view(self, state, w_cindex+2, v_cindex+2, vnode, 2, lvl+1, x, y+ssize, z, ssize)
    recursive_update_view(self, state, w_cindex+3, v_cindex+3, vnode, 3, lvl+1, x, y+ssize, z+ssize, ssize)
    recursive_update_view(self, state, w_cindex+4, v_cindex+4, vnode, 4, lvl+1, x+ssize, y, z, ssize)
    recursive_update_view(self, state, w_cindex+5, v_cindex+5, vnode, 5, lvl+1, x+ssize, y, z+ssize, ssize)
    recursive_update_view(self, state, w_cindex+6, v_cindex+6, vnode, 6, lvl+1, x+ssize, y+ssize, z, ssize)
    recursive_update_view(self, state, w_cindex+7, v_cindex+7, vnode, 7, lvl+1, x+ssize, y+ssize, z+ssize, ssize)
  end
end

-- Update view SVO from world SVO (step).
-- x,y,z: view center (meters)
-- min_dist: the LOD decreases beyond this distance (meters)
-- leaf_lod_level: maximum LOD to track, all blocks are loaded beyond it
function world:updateView(x, y, z, min_dist, leaf_lod_level)
  local state = {
    x = x, y = y, z = z,
    min_dist = min_dist,
    leaf_lod_level = leaf_lod_level
  }
  -- build view update buffer
  state.allocated = 64
  state.used = 1
  state.buffer = love.data.newByteData(state.allocated*12)
  state.p_buffer = ffi.cast("uint8_t*", state.buffer:getFFIPointer())

  local size = 2^(self.levels-1)*self.unit
  recursive_update_view(self, state, 0, 0, {[0] = self.view_tree}, 0, 0, -size/2, -size/2, -size/2, size)
end

return world
