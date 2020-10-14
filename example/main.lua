local VoxR = require("love-VoxR")
local DPBR = require("love-DPBR")
local mgl = require("MGL")
mgl.gen_vec(3); mgl.gen_mat(3)
mgl.gen_vec(4); mgl.gen_mat(4)

local svo, shader, scene
local proj = mgl.perspective(math.pi/2, 16/9, 0.05, 50)
local inv_proj = mgl.inverse(proj)

local speed = 5
local ax = mgl.vec3(1,0,0)
local ay = mgl.vec3(0,1,0)
local az = mgl.vec3(0,0,1)
local camera = {p = mgl.vec3(-2.5,0,0), phi = -math.pi/2, theta = math.pi/2}
local function update_cam()
  camera.model = mgl.translate(camera.p)*mgl.rotate(az, camera.phi)*mgl.rotate(ax, camera.theta)
  camera.view = mgl.inverse(camera.model)
end
update_cam()

function love.load()
  love.mouse.setRelativeMode(true)

  scene = DPBR.newScene(1280,720)
  scene:setProjection(proj, inv_proj)
  scene:setDepth("raw")
  scene:setToneMapping("filmic")
  scene:setAntiAliasing("FXAA")
  scene:setAmbientBRDF(love.graphics.newImage("BRDF_LUT.exr"))

  svo = VoxR.newSVO(17, 0.125)
  --svo:fill(0,0,0, 2^13,1,1, 0,125,0, 255,0,0)
  --svo:fill(-2^18,-2^18,-2^18, 2^18,2^18,2^18, 0,125,0, 255,0,0)
  svo:fill(0,0,0, 10,1,1, 0,125,0, 255,0,0)
  svo:fill(0,0,0, 1,10,1, 0,125,0, 0,255,0)
  svo:fill(0,0,0, 1,1,10, 0,125,0, 0,0,255)
  print("blocks", svo:countBlocks(), svo:countBytes())
  local dir = mgl.normalize(mgl.vec3(-1,0,0))
  local r = svo:castRay(10,0,0.12, dir.x, dir.y, dir.z)
  for k,v in pairs(r or {}) do print(k,v) end

  shader = VoxR.newShaderSVO(17)
  shader:send("proj", proj)
  shader:send("inv_proj", inv_proj)
end

function love.update(dt)
  -- camera translation
  local dir = mgl.mat3(camera.model)*mgl.vec3(0,0,-1)
  local side = mgl.normalize(mgl.cross(dir, az))

  local is_down = love.keyboard.isScancodeDown
  local vdir = ((is_down("w") and 1 or 0)+(is_down("s") and -1 or 0))*speed*dt
  local vside = ((is_down("a") and -1 or 0)+(is_down("d") and 1 or 0))*speed*dt
  camera.p = camera.p+vdir*dir+vside*side

  -- compute camera transform
  update_cam()
  shader:send("view", camera.view)
  shader:send("inv_view", camera.model)
end

function love.mousemoved(x, y, dx, dy)
  camera.phi = camera.phi-dx*math.pi*1e-3
  camera.theta = math.min(math.max(camera.theta-dy*math.pi*1e-3, math.pi*0.1), math.pi*0.9)
end

function love.draw()
  scene:bindMaterialPass()
  svo:bindShader(shader)
  love.graphics.rectangle("fill", 0, 0, 1280, 720)
  love.graphics.setShader()

  scene:bindLightPass()
  scene:drawAmbientLight(0.1)
  scene:drawEmissionLight()
  scene:drawPointLight(0,0,0.1,100,10)

  scene:bindBackgroundPass()
  love.graphics.clear(0,0,0,1)
  scene:bindBlendPass()
  scene:render()
end
