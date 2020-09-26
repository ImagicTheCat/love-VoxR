local VoxR = require("love-VoxR")

function love.load()
  local svo = VoxR.newSVO(20, 0.125)
  svo:fill(0,0,0, 1,1,1, 0,125,0, 255,0,0)
  print(svo:countBlocks())
  svo:fill(0,0,0, 1,1,1, 0,125,0, 255,0,0)
  print(svo:countBlocks())
end
