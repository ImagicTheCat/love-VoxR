-- https://github.com/ImagicTheCat/love-VoxR
-- MIT license (see LICENSE or src/love-VoxR.lua)

--[[
MIT License

Copyright (c) 2020 ImagicTheCat

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local ffi = require("ffi")
local bit = require("bit")
local lshift, rshift, bswap = bit.lshift, bit.rshift, bit.bswap

-- detect uint32 endianness
local CINDEX_LE
do
  local v = ffi.new("union{ uint32_t dw; uint8_t bs[4]; }")
  v.dw = 0xff; CINDEX_LE = (v.bs[0] == 0xff)
end

local VoxR = {}

-- SVO
local SVO = {}
local SVO_meta = {__index = SVO}

-- Each block is stored as 3 uint8vec4 elements.
--- (metalness, roughness, emission, flags)
--- (r, g, b, ...)
--- (B3, B2, B1, B0): uint32 block index (0-based) of the 8 packed children (0 if none)
--- The block at index 0 is the root node.
-- Levels go bottom-up, they start at 0 (unit level) to levels-1 (maximum level, the root node).
function VoxR.newSVO(levels, unit)
  local base_blocks = 64
  local o = setmetatable({
    levels = levels,
    unit = unit,
    allocated_blocks = base_blocks, -- allocated memory
    used_blocks = 1, -- used memory (segment)
    available_cblocks = {}, -- 8 packed children blocks indexes (stack)
    buffer = love.data.newByteData(base_blocks*12),
    vbuffer = love.graphics.newBuffer({{format = "uint8vec4"}}, base_blocks*3, {texel=true})
  }, SVO_meta)

  o.p_buffer = ffi.cast("uint8_t*", o.buffer:getFFIPointer())
  o.vbuffer:setArrayData(o.buffer, 1)
  return o
end

-- allocate children blocks
local function SVO_allocateCBlock(self)
  local index = table.remove(self.available_cblocks)
  if not index then
    if self.allocated_blocks-self.used_blocks >= 8 then -- new blocks
      index = self.used_blocks
      self.used_blocks = index+8
    else -- not enough memory, double allocated blocks
      local old_allocated = self.allocated_blocks
      local old_buffer = self.buffer
      self.allocated_blocks = self.allocated_blocks*2
      self.buffer = love.data.newByteData(self.allocated_blocks*12)
      self.p_buffer = ffi.cast("uint8_t*", self.buffer:getFFIPointer())
      self.vbuffer:release()
      self.vbuffer = love.graphics.newBuffer({{format = "uint8vec4"}}, self.allocated_blocks*3, {texel=true})
      ffi.copy(self.p_buffer, old_buffer:getFFIPointer(), old_allocated*12)
      self.vbuffer:setArrayData(self.buffer, 1)
      old_buffer:release()

      index = SVO_allocateCBlock(self)
    end
  end
  ffi.fill(self.p_buffer+index*12, 8*12)
  return index
end

-- Get/set block cindex (uint32).
-- b: block ptr
-- v: (optional) value
local function block_cindex(b, v)
  local dw = ffi.cast("uint32_t*", b)
  if CINDEX_LE then
    if v then
      v = bswap(v)
      if v < 0 then v = v+0x100000000 end
      dw[2] = v
    else
      v = bswap(dw[2])
      if v < 0 then v = v+0x100000000 end
      return v
    end
  else
    if v then dw[2] = v else return dw[2] end
  end
end

-- free 8 packed children blocks
local function SVO_freeCBlock(self, cindex)
  table.insert(self.available_cblocks, cindex)
  -- recursive
  for i=cindex, cindex+7 do
    local sub_cindex = block_cindex(self.p_buffer+i*12)
    if sub_cindex ~= 0 then SVO_freeCBlock(self, sub_cindex) end
  end
end

-- state: fill data
-- index: block index
-- x,y,z: block origin in SVO-voxels coordinates
-- size: block size (voxels)
local function SVO_recursive_fill(self, state, index, x, y, z, size)
--  print("SVO fill", index, x, y, z, size)
  -- compute intersection between block area and fill area
  local x1, x2 = math.max(state.x1, x), math.min(state.x2, x+size)
  local y1, y2 = math.max(state.y1, y), math.min(state.y2, y+size)
  local z1, z2 = math.max(state.z1, z), math.min(state.z2, z+size)

  if x1 == x and y1 == y and z1 == z --
    and x2 == x+size and y2 == y+size and z2 == z+size then -- full
    local b = self.p_buffer+index*12
    -- set block data
    if state.metalness then
      b[0], b[1], b[2], b[3] = state.metalness, state.roughness, state.emission, 0x01
      b[4], b[5], b[6], b[7] = state.r, state.g, state.b, 0
    else -- empty
      b[3] = 0
    end
    -- free children
    local cindex = block_cindex(b)
    if cindex ~= 0 then
      block_cindex(b, 0) -- reset cindex
      SVO_freeCBlock(self, cindex)
    end
  elseif x1 < x2 and y1 < y2 and z1 < z2 then -- partial (recursion)
    -- get/create children blocks
    local cindex = block_cindex(self.p_buffer+index*12)
    if cindex == 0 then
      cindex = SVO_allocateCBlock(self)
      block_cindex(self.p_buffer+index*12, cindex)
    end
    local ssize = size/2
    SVO_recursive_fill(self, state, cindex, x, y, z, ssize)
    SVO_recursive_fill(self, state, cindex+1, x, y+ssize, z, ssize)
    SVO_recursive_fill(self, state, cindex+2, x, y, z+ssize, ssize)
    SVO_recursive_fill(self, state, cindex+3, x, y+ssize, z+ssize, ssize)
    SVO_recursive_fill(self, state, cindex+4, x+ssize, y, z, ssize)
    SVO_recursive_fill(self, state, cindex+5, x+ssize, y+ssize, z, ssize)
    SVO_recursive_fill(self, state, cindex+6, x+ssize, y, z+ssize, ssize)
    SVO_recursive_fill(self, state, cindex+7, x+ssize, y+ssize, z+ssize, ssize)
  end
end

-- Fill the SVO with a voxel area.
-- x1, y1, z1, x2, y2, z2: area boundaries
-- metalness, roughness, emission, r, g, b: (optional) voxel data (nothing = empty voxels)
function SVO:fill(x1, y1, z1, x2, y2, z2, metalness, roughness, emission, r, g, b)
  local state = {
    x1 = x1, y1 = y1, z1 = z1,
    x2 = x2, y2 = y2, z2 = z2,
    metalness = metalness,
    roughness = roughness,
    emission = emission,
    r = r, g = g, b = b
  }
  local size = 2^(self.levels-1)
  SVO_recursive_fill(self, state, 0, -size/2, -size/2, -size/2, size)
end

local function SVO_recursive_raycast(self, tx0, ty0, tz0, tx1, ty1, tz1, index, cmask)
  if tx1 < 0 or ty1 < 0 or tz1 < 0 then return end
  -- recursion
  local cindex = block_cindex(self.p_buffer+index*12)
  if cindex > 0 then
    local txm, tym, tzm = (tx0+tx1)/2, (ty0+ty1)/2, (tz0+tz1)/2
    -- find entry plane
    local mt0 = math.min(tx0, ty0, tz0)
    if mt0 == tx0 then -- YZ
    elseif mt0 == ty0 then -- XZ
    else -- XY
    end
  end
end

function SVO:castRay(ox, oy, oz, dx, dy dz)
  local size = 2^(self.levels-1)*self.unit
  -- next child bit flip mask
  local cmask = 0
  if dx < 0 then ox = size-ox; dx = -dx; cmask = cmask+4 end
  if dy < 0 then oy = size-oy; dy = -dy; cmask = cmask+2 end
  if dz < 0 then oz = size-oz; dz = -dz; cmask = cmask+1 end
  -- compute root pcmaskrcmaskmeters
  local msize = size/2
  local tx0 = (-msize-ox)/dx
  local tx1 = (msize-ox)/dx
  local ty0 = (-msize-oy)/dy
  local ty1 = (msize-oy)/dy
  local tz0 = (-msize-oz)/dz
  local tz1 = (msize-oz)/dz
  -- check contact
  if math.max(tx0, ty0, tz0) < math.min(tx1, ty1, tz1) then
    SVO_recursive_raycast(self, tx0, ty0, tz0, tx1, ty1, tz1, 0, cmask)
  end
end

-- return effective blocks count (used_blocks - available_cblocks x 8)
function SVO:countBlocks()
  return self.used_blocks-#self.available_cblocks*8
end
function SVO:countBytes() return self.allocated_blocks*12 end

return VoxR
