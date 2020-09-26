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
    allocated_blocks = base_blocks,
    used_blocks = 1,
    available_cblocks = {}, -- 8 packed children blocks indexes (stack)
    buffer = love.data.newByteData(base_blocks*3*4),
    vbuffer = love.graphics.newBuffer({{format = "uint8vec4"}}, base_blocks*3, {texel=true})
  }, SVO_meta)

  o.p_buffer = ffi.cast("uint8_t*", o.buffer:getFFIPointer())
  o.vbuffer:setArrayData(o.buffer, 1)
  return o
end

-- allocate children blocks
local function SVO_allocateCBlock(self)
  local index = table.remove(self.available_blocks)
  if not index then
    if self.allocated_blocks-self.used_blocks >= 8 then -- new blocks
      index = self.used_blocks
      self.used_blocks = index+8
      ffi.fill(self.p_buffer+index, 12*8)
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
  return index
end

-- Get/set block cindex (uint32).
-- b: block ptr
-- v: (optional) value
local function block_cindex(b, v)
  local dw = ffi.cast("uint32_t*", b)
  if v then dw[2] = (CINDEX_LE and bswap(v)+0x0fffffff or v)
  else return CINDEX_LE and bswap(dw[2])+0x0fffffff or dw[2] end
end

-- free 8 packed children blocks
local function SVO_freeCBlock(self, index)
  table.insert(self.available_cblocks, index)
  -- recursive
  local cindex = block_cindex(self.p_buffer+index*12)
  if cindex ~= 0 then
    for i=cindex, cindex+8 do SVO_freeCBlock(self, i) end
  end
end

-- state: fill data
-- index: block index
-- x,y,z: block origin in SVO-voxels coordinates
-- size: block size (voxels)
local function SVO_recursive_fill(self, state, index, x, y, z, size)
  -- compute intersection between block area and fill area
  local x1, x2 = math.max(state.x1, x), math.min(state.x2, x+size)
  local y1, y2 = math.max(state.y1, x), math.min(state.y2, y+size)
  local z1, z2 = math.max(state.z1, x), math.min(state.z2, z+size)

  if x1 == x and y1 == y and z1 == z --
    and x2 == x+size and y2 == y+size and z2 == z+size then -- full
    local b = self.p_buffer+index*12
    -- set block data
    b[0], b[1], b[2], b[3] = state.metalness, state.roughness, state.emission, 0
    b[4], b[5], b[6], b[7] = state.r, state.g, state.b, 0
    -- free children
    local cindex = block_cindex(b)
    if cindex ~= 0 then
      block_cindex(b, 0)
      for i=cindex, cindex+8 do SVO_freeCBlock(self, i) end
    end
  elseif x1 < x2 or y1 < y2 or z1 < z2 then -- partial (recursion)
    local b = self.p_buffer+index*12
    -- get/create children blocks
    local cindex = block_cindex(b)
    if cindex == 0 then
      cindex = allocateCBlock(self)
      block_cindex(b, cindex)
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

function SVO:fill(x1, y1, z1, x2, y2, z2, metalness, roughness, emission, r, g, b)
end

SVO.fill = SVO_fill

return VoxR
