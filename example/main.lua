local VoxR = require("love-VoxR")

function love.load()
  local svo = VoxR.newSVO(20, 0.125)
  svo:fill(0,0,0, 2^13,1,1, 0,125,0, 255,0,0)
  print("blocks", svo:countBlocks(), svo:countBytes())
  svo:fill(-2^18, -2^18, -2^18, 2^18, 2^18, 2^18)
  print("blocks", svo:countBlocks(), svo:countBytes())
end
