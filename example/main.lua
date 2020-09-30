local VoxR = require("love-VoxR")
local mgl = require("MGL")
mgl.gen_vec(3)

function love.load()
  local svo = VoxR.newSVO(20, 0.125)
  svo:fill(0,0,0, 2^13,1,1, 0,125,0, 255,0,0)
  print("blocks", svo:countBlocks(), svo:countBytes())
  local dir = mgl.normalize(mgl.vec3(1,0,0))
  local r = svo:castRay(10,0,0.12, dir.x, dir.y, dir.z)
  for k,v in pairs(r or {}) do print(k,v) end
  svo:fill(-2^18, -2^18, -2^18, 2^18, 2^18, 2^18)
  print("blocks", svo:countBlocks(), svo:countBytes())
end
