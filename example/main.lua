local VoxR = require("love-VoxR")
local mgl = require("MGL")
mgl.gen_vec(3)

function love.load()
  local svo = VoxR.newSVO(20, 0.125)
  svo:fill(0,0,0, 2^13,1,1, 0,125,0, 255,0,0)
  print("blocks", svo:countBlocks(), svo:countBytes())
  local dir = mgl.normalize(mgl.vec3(1,1,0))
  svo:castRay(0,0,0, dir.x, dir.y, dir.z)
  svo:fill(-2^18, -2^18, -2^18, 2^18, 2^18, 2^18)
  print("blocks", svo:countBlocks(), svo:countBytes())
end
