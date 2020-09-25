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
local VoxR = {}

-- SVO
local SVO = {}
local SVO_meta = {__index = SVO}

-- Each block is stored as 3 uint8vec4 elements.
--- (metalness, roughness, emission, flags)
--- (r, g, b, ...)
--- (B3, B2, B1, B0): uint32 block index (0-based) of the 8 packed children (0 if none)
--- The block at index 0 is the root node.
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
  o.vbuffer:setArrayData(o.buffer, 1, 3*base_blocks)
  return o
end

local function allocateCBlock(self)
  if 
end

local function freeCBlock(self, index)
end

return VoxR
