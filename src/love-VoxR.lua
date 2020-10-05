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
local lshift, rshift, bswap, bxor, band = bit.lshift, bit.rshift, bit.bswap, bit.bxor, bit.band

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
  local view = love.data.newDataView(self.buffer, index*12, 8*12)
  self.vbuffer:setArrayData(view, 1+index*3)
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
    -- update vbuffer
    local view = love.data.newDataView(self.buffer, index*12, 12)
    self.vbuffer:setArrayData(view, 1+index*3)
  elseif x1 < x2 and y1 < y2 and z1 < z2 then -- partial (recursion)
    -- get/create children blocks
    local cindex = block_cindex(self.p_buffer+index*12)
    if cindex == 0 then
      cindex = SVO_allocateCBlock(self)
      block_cindex(self.p_buffer+index*12, cindex)
      local view = love.data.newDataView(self.buffer, index*12, 12)
      self.vbuffer:setArrayData(view, 1+index*3)
    end
    local ssize = size/2
    SVO_recursive_fill(self, state, cindex, x, y, z, ssize)
    SVO_recursive_fill(self, state, cindex+1, x, y, z+ssize, ssize)
    SVO_recursive_fill(self, state, cindex+2, x, y+ssize, z, ssize)
    SVO_recursive_fill(self, state, cindex+3, x, y+ssize, z+ssize, ssize)
    SVO_recursive_fill(self, state, cindex+4, x+ssize, y, z, ssize)
    SVO_recursive_fill(self, state, cindex+5, x+ssize, y, z+ssize, ssize)
    SVO_recursive_fill(self, state, cindex+6, x+ssize, y+ssize, z, ssize)
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

-- Select minimum value in 3 pairs.
-- return r1, r2 or r3
local function select_min(v1, r1, v2, r2, v3, r3)
  local min = math.min(v1, v2, v3)
  if min == v1 then return r1
  elseif min == v2 then return r2
  else return r3 end
end

-- Compute parametric tim value with infinity handling (parallel ray
-- generalization).
-- ti0, ti1: parameters
-- i1, i2: node axis boundaries
-- oi: ray origin component
local function compute_tim(ti0, ti1, i1, i2, oi)
  local tim = (ti0+ti1)/2
  if tim ~= tim then -- NaN
    return oi < (i1+i2)/2 and 1/0 or -1/0
  else return tim end
end

local function SVO_recursive_raycast(self, state, tx0, ty0, tz0, tx1, ty1, tz1, index, x, y, z, size)
  if tx1 < 0 or ty1 < 0 or tz1 < 0 then return end -- no intersection
  -- recursion
  local b = self.p_buffer+index*12
  local cindex = block_cindex(b)
  if cindex > 0 then
--    local txm, tym, tzm = (tx0+tx1)/2, (ty0+ty1)/2, (tz0+tz1)/2
    local txm = compute_tim(tx0, tx1, x, x+size, state.ox+state.msize)
    local tym = compute_tim(ty0, ty1, y, y+size, state.oy+state.msize)
    local tzm = compute_tim(tz0, tz1, z, z+size, state.oz+state.msize)
    -- find entry plane
    local mt0 = math.max(tx0, ty0, tz0)
    -- find first child
    local node = 0
    if mt0 == tx0 then -- YZ
      node = (tym < tx0 and 2 or 0)+(tzm < tx0 and 1 or 0)
    elseif mt0 == ty0 then -- XZ
      node = (txm < ty0 and 4 or 0)+(tzm < ty0 and 1 or 0)
    else -- XY
      node = (txm < tz0 and 4 or 0)+(tym < tz0 and 2 or 0)
    end
    -- iterate on children
    local ssize = size/2
    while node < 8 and not state.index do
      if node == 0 then
        SVO_recursive_raycast(self, state, tx0, ty0, tz0, txm, tym, tzm, cindex+state.cmask,
          x, y, z, ssize)
        node = select_min(txm, 4, tym, 2, tzm, 1)
      elseif node == 1 then
        SVO_recursive_raycast(self, state, tx0, ty0, tzm, txm, tym, tz1, cindex+bxor(state.cmask, 1),
          x, y, z+ssize, ssize)
        node = select_min(txm, 5, tym, 3, tz1, 8)
      elseif node == 2 then
        SVO_recursive_raycast(self, state, tx0, tym, tz0, txm, ty1, tzm, cindex+bxor(state.cmask, 2),
          x, y+ssize, z, ssize)
        node = select_min(txm, 6, ty1, 8, tzm, 3)
      elseif node == 3 then
        SVO_recursive_raycast(self, state, tx0, tym, tzm, txm, ty1, tz1, cindex+bxor(state.cmask, 3),
          x, y+ssize, z+ssize, ssize)
        node = select_min(txm, 7, ty1, 8, tz1, 8)
      elseif node == 4 then
        SVO_recursive_raycast(self, state, txm, ty0, tz0, tx1, tym, tzm, cindex+bxor(state.cmask, 4),
          x+ssize, y, z, ssize)
        node = select_min(tx1, 8, tym, 6, tzm, 5)
      elseif node == 5 then
        SVO_recursive_raycast(self, state, txm, ty0, tzm, tx1, tym, tz1, cindex+bxor(state.cmask, 5),
          x+ssize, y, z+ssize, ssize)
        node = select_min(tx1, 8, tym, 7, tz1, 8)
      elseif node == 6 then
        SVO_recursive_raycast(self, state, txm, tym, tz0, tx1, ty1, tzm, cindex+bxor(state.cmask, 6),
          x+ssize, y+ssize, z, ssize)
        node = select_min(tx1, 8, ty1, 8, tzm, 7)
      elseif node == 7 then
        SVO_recursive_raycast(self, state, txm, tym, tzm, tx1, ty1, tz1, cindex+bxor(state.cmask, 7),
          x+ssize, y+ssize, z+ssize, ssize)
        node = 8
      end
    end
  elseif cindex == 0 and band(b[3], 0x01) ~= 0 then -- non-empty leaf, intersection
    -- compute ray data
    state.index = index
    --- intersection position (with parallel ray generalization)
    state.px = state.ox+(state.dx ~= 0 and tx0*state.dx or 0)
    state.py = state.oy+(state.dy ~= 0 and ty0*state.dy or 0)
    state.pz = state.oz+(state.dz ~= 0 and tz0*state.dz or 0)
    --- face normal
    state.nx, state.ny, state.nz = 0, 0, 0
    local mt0 = math.max(tx0, ty0, tz0) -- find entry plane
    if mt0 == tx0 then state.nx = state.dx < 0 and 1 or -1 -- YZ plane
    elseif mt0 == ty0 then state.ny = state.dy < 0 and 1 or -1 -- XZ plane
    else state.nz = state.dz < 0 and 1 or -1 end -- XY plane
    --- voxel coordinates
    state.vx = math.floor(state.px/self.unit-state.nx*0.5)
    state.vy = math.floor(state.py/self.unit-state.ny*0.5)
    state.vz = math.floor(state.pz/self.unit-state.nz*0.5)
  end
end

-- Ray-casting in SVO space (first full voxel).
-- return ray state on intersection, nil otherwise
function SVO:castRay(ox, oy, oz, dx, dy, dz)
  -- The SVO is considered between 0 and size instead of -msize and msize for
  -- the traversal algorithm.
  local size = 2^(self.levels-1)*self.unit
  local msize = size/2
  local state = {
    ox = ox, oy = oy, oz = oz,
    dx = dx, dy = dy, dz = dz,
    msize = msize,
    cmask = 0
  }
  ox, oy, oz = ox+msize, oy+msize, oz+msize -- normalize coordinates
  -- negative direction generalization (compute next child bit flip mask)
  if dx < 0 then ox = size-ox; dx = -dx; state.cmask = state.cmask+4 end
  if dy < 0 then oy = size-oy; dy = -dy; state.cmask = state.cmask+2 end
  if dz < 0 then oz = size-oz; dz = -dz; state.cmask = state.cmask+1 end
  -- compute root parameters
  local tx0 = -ox/dx
  local tx1 = (size-ox)/dx
  local ty0 = -oy/dy
  local ty1 = (size-oy)/dy
  local tz0 = -oz/dz
  local tz1 = (size-oz)/dz
  -- check intersection
  if math.max(tx0, ty0, tz0) < math.min(tx1, ty1, tz1) then
    SVO_recursive_raycast(self, state, tx0, ty0, tz0, tx1, ty1, tz1, 0, 0, 0, 0, size)
  end

  if state.index then return state end
end

-- return effective blocks count (used_blocks - available_cblocks x 8)
function SVO:countBlocks()
  return self.used_blocks-#self.available_cblocks*8
end
function SVO:countBytes() return self.allocated_blocks*12 end

function SVO:bindShader(shader, max_its)
  shader:send("unit", self.unit)
  shader:send("levels", self.levels)
  shader:send("buffer", self.vbuffer)
  shader:send("max_its", max_its or 100)
  love.graphics.setShader(shader)
end

-- Shaders

local SVO_SHADER = [[
#pragma language glsl3

uniform mat4 proj, inv_proj, view, inv_view;
uniform usamplerBuffer buffer;
uniform float unit;
uniform int levels;
uniform int max_its;

struct SVOrt_Frame{
  uint cindex;
  int node;
  vec3 t0, t1, tm;
  vec3 or; // origin
  float msize;
};

struct SVOrt_State{
  int si; // stack index
  vec3 ro, rd; // original ray
  float msize;
  uint cmask;
  int index; // intersected index
  vec3 p, n;
};

uint block_cindex(uint index)
{
  uvec4 dw = texelFetch(buffer, int(index*3u)+2);
  return (dw.x << 24)+(dw.y << 16)+(dw.z << 8)+dw.w;
}

float compute_tim(float ti0, float ti1, float i1, float i2, float oi)
{
  float tim = (ti0+ti1)/2.0;
  if(isnan(tim))
    return (oi < (i1+i2)/2.0 ? 1.0/0.0 : -1.0/0.0);
  else
    return tim;
}

int select_min(float v1, int r1, float v2, int r2, float v3, int r3)
{
  float m = min(v1, min(v2, v3));
  if(m == v1) return r1;
  else if(m == v2) return r2;
  else return r3;
}

void SVOrt_begin_frame(inout SVOrt_State state, inout SVOrt_Frame f, vec3 t0, vec3 t1, uint index, vec3 or, float size)
{
  state.si++;
  f.t0 = t0;
  f.t1 = t1;
  f.or = or; // origin
  f.msize = size/2.0;

  if(f.t1.x < 0 || f.t1.y < 0 || f.t1.z < 0){ // no intersection
    state.si--; // end frame
    return;
  }

  f.cindex = block_cindex(index);
  if(f.cindex > 0u){ // recursion
    f.tm.x = compute_tim(t0.x, t1.x, or.x, or.x+size, state.ro.x+state.msize);
    f.tm.y = compute_tim(t0.y, t1.y, or.y, or.y+size, state.ro.y+state.msize);
    f.tm.z = compute_tim(t0.z, t1.z, or.z, or.z+size, state.ro.z+state.msize);
    // find entry plane
    float mt0 = max(t0.x, max(t0.y, t0.z));
    // find first child
    if(mt0 == t0.x) // YZ
      f.node = (f.tm.y < t0.x ? 2 : 0)+(f.tm.z < t0.x ? 1 : 0);
    else if(mt0 == t0.y) // XZ
      f.node = (f.tm.x < t0.y ? 4 : 0)+(f.tm.z < t0.y ? 1 : 0);
    else // XY
      f.node = (f.tm.x < t0.z ? 4 : 0)+(f.tm.y < t0.z ? 2 : 0);
    // Will iterate the children from here.
  }
  else{
    uvec4 MREF = texelFetch(buffer, int(index*3u));
    if((MREF.w & 0x01u) != 0u){ // non-empty leaf, intersection
      // compute ray data
      state.index = int(index);
      /// intersection position (with parallel ray generalization)
      state.p.x = state.ro.x+(state.rd.x != 0.0 ? t0.x*state.rd.x : 0.0);
      state.p.y = state.ro.y+(state.rd.y != 0.0 ? t0.y*state.rd.y : 0.0);
      state.p.z = state.ro.z+(state.rd.z != 0.0 ? t0.z*state.rd.z : 0.0);
      /// face normal
      state.n = vec3(0.0);
      float mt0 = max(t0.x, max(t0.y, t0.z)); // find entry plane
      if(mt0 == t0.x) state.n.x = state.rd.x < 0.0 ? 1.0 : -1.0; // YZ plane
      else if(mt0 == t0.y) state.n.y = state.rd.y < 0.0 ? 1.0 : -1.0; // XZ plane
      else state.n.z = state.rd.z < 0.0 ? 1.0 : -1.0; // XY plane
    }
    state.si--; // end frame
  }
}

bool raytraceSVO(vec3 ro, vec3 rd, out vec3 p, out vec3 n,
  out uvec3 MRE, out uvec3 albedo)
{
  // The SVO is considered between 0 and size instead of -msize and msize for
  // the traversal algorithm.
  float size = float(1 << (levels-1))*unit;
  SVOrt_State state;
  SVOrt_Frame stack[$MAX_DEPTH]; // stack frames
  state.index = -1;
  state.ro = ro;
  state.rd = rd;
  state.cmask = 0u;
  state.si = -1;
  state.msize = size/2.0;

  vec3 roN = ro+vec3(state.msize); // normalize ray origin
  vec3 rdN = rd;
  // negative direction generalization (compute next child bit flip mask)
  if(rdN.x < 0){ roN.x = size-roN.x; rdN.x = -rdN.x; state.cmask += 4u; }
  if(rdN.y < 0){ roN.y = size-roN.y; rdN.y = -rdN.y; state.cmask += 2u; }
  if(rdN.z < 0){ roN.z = size-roN.z; rdN.z = -rdN.z; state.cmask += 1u; }
  // compute root parameters
  vec3 t0 = -roN/rdN;
  vec3 t1 = (vec3(size)-roN)/rdN;
  // check intersection
  if(max(t0.x, max(t0.y, t0.z)) < min(t1.x, min(t1.y, t1.z))){
    // recursion
    int i = 0;
    SVOrt_begin_frame(state, stack[state.si+1], t0, t1, 0u, vec3(0), size);
    while(state.si >= 0 && i < max_its){
      int si = state.si;
      SVOrt_Frame f = stack[si];
      if(f.node < 8 && state.index < 0){
        switch(f.node){
          case 0:
            SVOrt_begin_frame(state, stack[si+1], f.t0, f.tm, f.cindex+state.cmask, f.or, f.msize);
            stack[si].node = select_min(f.tm.x, 4, f.tm.y, 2, f.tm.z, 1); break;
          case 1:
            SVOrt_begin_frame(state, stack[si+1], vec3(f.t0.x, f.t0.y, f.tm.z), vec3(f.tm.x, f.tm.y, f.t1.z), f.cindex+(state.cmask^1u), vec3(f.or.x, f.or.y, f.or.z+f.msize), f.msize);
            stack[si].node = select_min(f.tm.x, 5, f.tm.y, 3, f.t1.z, 8); break;
          case 2:
            SVOrt_begin_frame(state, stack[si+1], vec3(f.t0.x, f.tm.y, f.t0.z), vec3(f.tm.x, f.t1.y, f.tm.z), f.cindex+(state.cmask^2u), vec3(f.or.x, f.or.y+f.msize, f.or.z), f.msize);
            stack[si].node = select_min(f.tm.x, 6, f.t1.y, 8, f.tm.z, 3); break;
          case 3:
            SVOrt_begin_frame(state, stack[si+1], vec3(f.t0.x, f.tm.y, f.tm.z), vec3(f.tm.x, f.t1.y, f.t1.z), f.cindex+(state.cmask^3u), vec3(f.or.x, f.or.y+f.msize, f.or.z+f.msize), f.msize);
            stack[si].node = select_min(f.tm.x, 7, f.t1.y, 8, f.t1.z, 8); break;
          case 4:
            SVOrt_begin_frame(state, stack[si+1], vec3(f.tm.x, f.t0.y, f.t0.z), vec3(f.t1.x, f.tm.y, f.tm.z), f.cindex+(state.cmask^4u), vec3(f.or.x+f.msize, f.or.y, f.or.z), f.msize);
            stack[si].node = select_min(f.t1.x, 8, f.tm.y, 6, f.tm.z, 5); break;
          case 5:
            SVOrt_begin_frame(state, stack[si+1], vec3(f.tm.x, f.t0.y, f.tm.z), vec3(f.t1.x, f.tm.y, f.t1.z), f.cindex+(state.cmask^5u), vec3(f.or.x+f.msize, f.or.y, f.or.z+f.msize), f.msize);
            stack[si].node = select_min(f.t1.x, 8, f.tm.y, 7, f.t1.z, 8); break;
          case 6:
            SVOrt_begin_frame(state, stack[si+1], vec3(f.tm.x, f.tm.y, f.t0.z), vec3(f.t1.x, f.t1.y, f.tm.z), f.cindex+(state.cmask^6u), vec3(f.or.x+f.msize, f.or.y+f.msize, f.or.z), f.msize);
            stack[si].node = select_min(f.t1.x, 8, f.t1.y, 8, f.tm.z, 7); break;
          case 7:
            SVOrt_begin_frame(state, stack[si+1], f.tm, f.t1, f.cindex+(state.cmask^7u), f.or+vec3(f.msize), f.msize);
            stack[si].node = 8; break;
        }
      }
      else
        state.si--; // end frame
      i++;
    }
  }

  if(state.index >= 0){
    p = state.p;
    n = state.n;
    int b = state.index*3;
    MRE = uvec3(texelFetch(buffer, b));
    albedo = uvec3(texelFetch(buffer, b+1));
    return true;
  }
  else
    return false;
}

void effect()
{
  // compute ray
  vec3 ndc = vec3(love_PixelCoord/love_ScreenSize.xy, 0);
  ndc.y = 1.0-ndc.y;
  ndc = ndc*2.0-vec3(1);
  vec4 v = inv_proj*vec4(ndc, 1);
  v /= v.w;
  vec3 ro = vec3(inv_view*v);
  vec3 rd = mat3(inv_view)*normalize(v.xyz);

  vec3 p, n;
  uvec3 MRE, albedo;
  if(!raytraceSVO(ro, rd, p, n, MRE, albedo))
    discard;

  n = mat3(view)*n;
  vec4 p_ndc = proj*view*vec4(p, 1);
  p_ndc /= p_ndc.w;

  // depth
  gl_FragDepth = p_ndc.z;
  // albedo
  love_Canvases[0] = vec4(albedo/255.0,1);
  // normal
  love_Canvases[1] = vec4((n*vec3(1,-1,-1)+vec3(1))/2, 1.0);
  // MRA
  love_Canvases[2] = vec4(MRE.x/255.0, MRE.y/255.0, 1.0, 1.0);
  // emission
  love_Canvases[3] = vec4(vec3(MRE.z),1);
}
]]

function VoxR.newShaderSVO(max_depth)
  -- "$..." template substitution
  local code = SVO_SHADER:gsub("%$([%w_]+)", {
    MAX_DEPTH = max_depth
  })
  return love.graphics.newShader(code)
end

return VoxR
