-- ActivityRing_v1.lua
-- Rive Particle System explicitly designed for filling a Circular bounds

local Physics = require('Physics')

--=============================================================================
-- ACTIVITY RING SCRIPT - USAGE INSTRUCTIONS
--=============================================================================
-- To make this script work in Rive, follow these setup steps:
--
-- 1. PARTICLE ARTBOARDS (The Bubbles)
--    You need 5 separate artboards for the different particle variations.
--    Each of these 5 artboards MUST have a View Model (VM) with these EXACT properties:
--      * `type` (Number): Used to differentiate the visual styling if needed.
--      * `active` (Boolean): Determines if the user has tapped/activated it.
--      * `pointerOver` (Boolean): True when the mouse/pointer hovers over the particle.
--
-- 2. MAIN ARTBOARD (The Sandbox)
--    Connect this script to a Custom Node in your main artboard.
--    Hook up the following Node Inputs to your Main Artboard's VM or State Machine:
--      * `artboard1` ... `artboard5`: Connect to the 5 particle artboards created in step 1.
--      * `activate` (Trigger): Fire this trigger to start the overall simulation.
--      * `goal` (Number): Your daily target (e.g., 143). This calculatingly dictates the
--                         exact static radius of the big container circle.
--      * `activeMinutes` (Number): Drive this dynamically. The script will emit particles
--                                  one-by-one from the bottom until it matches this number.
--
-- 3. PHYSICS & TIMING PARAMETERS
--      * `growTime`: Time in seconds it takes for a newly spawned particle to reach full size.
--      * `emissionInterval`: Frames between each particle spawn.
--      * `packingFactor`: How tightly packed the circle should be evaluated (e.g., 0.85).
--=============================================================================

-- Type definitions
type ParticleVM = {
  type: Property<number>,
  active: Property<boolean>,
  pointerOver: Property<boolean>,
}

type Particle = {
  id: number,
  x: number,
  y: number,
  prevX: number,
  prevY: number,
  vx: number,
  vy: number,
  cx: number,
  cy: number,
  sleeping: boolean,
  colRadius: number,
  nextInCell: Particle?,
  -- Extended fields
  radius: number,
  originalRadius: number,
  instance: Artboard<ParticleVM>,
  sleepTimer: number,
  currentT: number,
  type: number,
  bpm: number,
}

type ParticleSystemNode = {
  -- Inputs
  artboard1: Input<Artboard<ParticleVM>>,
  artboard2: Input<Artboard<ParticleVM>>,
  artboard3: Input<Artboard<ParticleVM>>,
  artboard4: Input<Artboard<ParticleVM>>,
  artboard5: Input<Artboard<ParticleVM>>,
  activate: Input<Trigger>,

  friction: Input<number>,
  damping: Input<number>,
  gravity: Input<number>,
  sizeMultiplier: Input<number>,
  size1: Input<number>,
  size2: Input<number>,
  mainCircleSize: Input<number>,
  emissionInterval: Input<number>,
  growTime: Input<number>,

  goal: Input<number>,
  activeMinutes: Input<number>,
  packingFactor: Input<number>,

  -- Graphics
  circlePath: Path,
  circlePaint: Paint,

  -- State
  _particles: { Particle },
  mat: Mat2D,
  nextId: number,
  totalSpawned: number,
  spawnDelayCounter: number,
  pointerPos: { x: number, y: number },
  started: boolean,
}

local activate: (self: ParticleSystemNode) -> ()

local mfloor = math.floor
local mmax = math.max
local mmin = math.min
local mrandom = math.random
local table_insert = table.insert

local BASE_RADIUS = 10
local CELL_SIZE = 40
local SUBSTEPS = 8
local MAX_VELOCITY = 1500
local SLEEP_VELOCITY_THRESH = 15
local SLEEP_TIME_THRESH = 1.0

local function cubicEaseOut(t: number): number
  return 1 - (1 - t) * (1 - t) * (1 - t)
end

-- Calculate Target Circle Radius
local function calculateCircleRadius(self: ParticleSystemNode): number
  if self.mainCircleSize and self.mainCircleSize > 0 then
    return self.mainCircleSize
  end
  local minSizeScale = 1.0
  local r_min = BASE_RADIUS * minSizeScale * self.sizeMultiplier
  local area_min = math.pi * r_min * r_min
  local total_area = self.goal * area_min
  local targetRadius = math.sqrt(total_area / (math.pi * self.packingFactor))
  return targetRadius
end

local function init(self: ParticleSystemNode, context: Context): boolean
  -- Wire the VM 'start' trigger directly so activate() fires on this instance
  local vm = context:viewModel()
  if vm then
    local startTrigger = vm:getTrigger('start')
    if startTrigger then
      startTrigger:addListener(function()
        activate(self)
      end)
    end
  end

  self.circlePath = Path.new()

  self.circlePaint = Paint.with({
    style = 'stroke',
    color = 0x80FFFFFF,
    thickness = 3.0,
  })

  self._particles = {}
  self.mat = Mat2D.identity()
  self.nextId = 1
  self.totalSpawned = 0
  self.spawnDelayCounter = 0
  self.pointerPos = { x = 0, y = 0 }
  self.started = false

  math.randomseed(os.time())
  return true
end

activate = function(self: ParticleSystemNode)
  self.started = true
end

local function spawnParticle(self: ParticleSystemNode, circleRadius: number)
  -- Generate random type (weighted could be added if needed)
  local ptType = mrandom(1, 5)

  local minB, maxB = 60, 170
  if ptType == 1 then
    minB, maxB = 52, 62
  elseif ptType == 2 then
    minB, maxB = 62, 70
  elseif ptType == 3 then
    minB, maxB = 70, 85
  elseif ptType == 4 then
    minB, maxB = 85, 120
  elseif ptType == 5 then
    minB, maxB = 120, 170
  end

  local ptBpm = mrandom(minB, maxB)

  local inputAb
  local targetRadius
  
  if ptType == 1 then
    inputAb = self.artboard1
    targetRadius = self.size1
  elseif ptType == 2 then
    inputAb = self.artboard2
    targetRadius = self.size1
  elseif ptType == 3 then
    inputAb = self.artboard3
    targetRadius = self.size2
  elseif ptType == 4 then
    inputAb = self.artboard4
    targetRadius = self.size2
  else
    inputAb = self.artboard5
    targetRadius = self.size2
  end

  local instance = inputAb:instance()
  if not instance then
    return
  end

  local t = 0
  if maxB > minB then
    t = (ptBpm - minB) / (maxB - minB)
  end

  targetRadius = targetRadius * self.sizeMultiplier

  instance:advance(0)

  if instance.data then
    if instance.data.type then
      instance.data.type.value = ptType
    end
    if instance.data.active then
      instance.data.active.value = false
    end
    if instance.data.pointerOver then
      instance.data.pointerOver.value = false
    end
  end

  -- Spawn at bottom center with slight jitter to prevent 0-length distances
  local jitterX = (math.random() - 0.5) * 2.0
  local spawnX = jitterX
  local spawnY = circleRadius - 5.0 -- Inside the bottom of the circle

  local newParticle: Particle = {
    id = self.nextId,
    x = spawnX,
    y = spawnY,
    prevX = spawnX,
    prevY = spawnY,
    vx = 0,
    vy = 0,
    radius = 0.5,
    originalRadius = targetRadius,
    instance = instance,
    cx = 0,
    cy = 0,
    sleeping = false,
    sleepTimer = 0,
    currentT = 0.0,
    colRadius = 0.5,
    nextInCell = nil,
    type = ptType,
    bpm = ptBpm,
  }

  table_insert(self._particles, newParticle)
  self.nextId = self.nextId + 1
  self.totalSpawned = self.totalSpawned + 1
end

local function pointerDown(self: ParticleSystemNode, event: PointerEvent)
  local parts = self._particles
  if not parts then
    return
  end

  local pos = event.position
  for i = #parts, 1, -1 do
    local p = parts[i]
    local dx = pos.x - p.x
    local dy = pos.y - p.y
    if dx * dx + dy * dy <= p.radius * p.radius then
      if p.instance.data and p.instance.data.active then
        p.instance.data.active.value = not p.instance.data.active.value
      end
      event:hit()
      return
    end
  end
end

local function pointerUp(self: ParticleSystemNode, event: PointerEvent)
  -- optional handling
end

local function pointerMove(self: ParticleSystemNode, event: PointerEvent)
  local pos = event.position
  self.pointerPos = { x = pos.x, y = pos.y }
end

local function advance(self: ParticleSystemNode, seconds: number): boolean
  if not self.started then
    return true
  end

  local dt = seconds
  if dt > 0.05 then
    dt = 0.05
  end

  local circleRadius = calculateCircleRadius(self)

  -- Spawning Logic: use activeMinutes if set, otherwise fill up to goal
  local targetCount = mfloor(self.activeMinutes)
  if targetCount <= 0 then
    targetCount = mfloor(self.goal)
  elseif targetCount > self.goal then
    targetCount = mfloor(self.goal)
  end

  if self.totalSpawned < targetCount then
    if self.spawnDelayCounter <= 0 then
      spawnParticle(self, circleRadius)
      self.spawnDelayCounter = mmax(1, mfloor(self.emissionInterval))
    else
      self.spawnDelayCounter = self.spawnDelayCounter - 1
    end
  end

  local parts = self._particles
  local pCount = #parts
  if pCount == 0 then
    return true
  end

  -- Interactions & Growth
  local growDur = mmax(0.01, self.growTime)
  local changeSpeed = dt / growDur
  local px, py = self.pointerPos.x, self.pointerPos.y

  for i = 1, pCount do
    local p = parts[i]

    -- Pointer Over
    if p.instance.data and p.instance.data.pointerOver then
      local dx = p.x - px
      local dy = p.y - py
      local isOver = (dx * dx + dy * dy) <= (p.radius * p.radius)
      if p.instance.data.pointerOver.value ~= isOver then
        p.instance.data.pointerOver.value = isOver
      end
    end

    -- Growth Animation
    if p.currentT < 1.0 then
      p.currentT = mmin(1.0, p.currentT + changeSpeed)
      local easeT = cubicEaseOut(p.currentT)
      p.radius = mmax(0.5, p.originalRadius * easeT)
      -- Constantly wake up while growing
      p.sleeping = false
    end

    -- Update physics radius
    p.colRadius = p.radius
  end

  -- Physics PBD Integration
  local substeps = SUBSTEPS
  local subDt = dt / substeps
  local gravity = self.gravity
  local friction = self.friction
  local damping = self.damping

  if subDt > 0.01 then
    subDt = 0.01
  end

  for step = 1, substeps do
    -- Integration
    for i = 1, pCount do
      local p = parts[i]
      if not p.sleeping then
        p.prevX = p.x
        p.prevY = p.y

        p.vy = p.vy + gravity * subDt
        p.x = p.x + p.vx * subDt
        p.y = p.y + p.vy * subDt
      end
    end

    -- Collision Solver
    local grid = Physics.buildGrid(parts :: { Physics.Particle }, CELL_SIZE)
    for i = 1, pCount do
      local p = parts[i]
      Physics.solveCollisions(grid, p :: Physics.Particle, 0.8)

      -- Circular Boundary Constraint
      if not p.sleeping then
        Physics.applyCircularBoundary(p :: Physics.Particle, 0, 0, circleRadius, friction)
      end
    end

    -- Velocity Update
    for i = 1, pCount do
      local p = parts[i]
      if not p.sleeping then
        local vx = (p.x - p.prevX) / subDt * damping
        local vy = (p.y - p.prevY) / subDt * damping

        if vx > MAX_VELOCITY then
          vx = MAX_VELOCITY
        elseif vx < -MAX_VELOCITY then
          vx = -MAX_VELOCITY
        end
        if vy > MAX_VELOCITY then
          vy = MAX_VELOCITY
        elseif vy < -MAX_VELOCITY then
          vy = -MAX_VELOCITY
        end

        p.vx = vx
        p.vy = vy
      end
    end
  end

  -- Post-physics sleeping logic
  for i = 1, pCount do
    local p = parts[i]
    if not p.sleeping then
      if
        p.vx * p.vx + p.vy * p.vy
        < SLEEP_VELOCITY_THRESH * SLEEP_VELOCITY_THRESH
      then
        p.sleepTimer = p.sleepTimer + dt
        if p.sleepTimer > SLEEP_TIME_THRESH and p.currentT >= 1.0 then
          p.sleeping = true
          p.vx, p.vy = 0, 0
        end
      else
        p.sleepTimer = 0
      end
    end
  end

  -- Update Graphics Instances
  for i = 1, pCount do
    parts[i].instance:advance(seconds)
  end

  return true
end

local function draw(self: ParticleSystemNode, renderer: Renderer)
  local circleRadius = calculateCircleRadius(self)

  -- Draw Circular Boundary Frame
  self.circlePath:reset()
  -- Approximate circle using 64-segment polygon (since :circle() may not be fully supported)
  local segments = 64
  for i = 0, segments do
    local angle = (i / segments) * math.pi * 2
    local vx = math.cos(angle) * circleRadius
    local vy = math.sin(angle) * circleRadius
    if i == 0 then
      self.circlePath:moveTo(Vector.xy(vx, vy))
    else
      self.circlePath:lineTo(Vector.xy(vx, vy))
    end
  end
  self.circlePath:close()

  renderer:drawPath(self.circlePath, self.circlePaint)

  local parts = self._particles
  if not parts then
    return
  end

  local mat = self.mat
  for i = 1, #parts do
    local p = parts[i]
    renderer:save()

    local scale = p.radius / BASE_RADIUS
    mat.xx = scale
    mat.yy = scale
    mat.tx = p.x
    mat.ty = p.y

    renderer:transform(mat)
    p.instance:draw(renderer)
    renderer:restore()
  end
end

return function(): Node<ParticleSystemNode>
  return {
    artboard1 = late(),
    artboard2 = late(),
    artboard3 = late(),
    artboard4 = late(),
    artboard5 = late(),

    friction = 0.5,
    damping = 0.985,
    gravity = 1500,
    sizeMultiplier = 1.0,
    size1 = 10,
    size2 = 10,
    mainCircleSize = 0, -- Set to > 0 to override dynamic calculation

    emissionInterval = 3,
    growTime = 0.8,

    goal = 143,
    activeMinutes = 0,
    packingFactor = 0.85,

    circlePath = Path.new(),
    circlePaint = Paint.new(),

    _particles = {},
    mat = Mat2D.identity(),

    nextId = 1,
    totalSpawned = 0,
    spawnDelayCounter = 0,
    pointerPos = { x = 0, y = 0 },

    started = false,

    init = init,
    advance = advance,
    activate = activate,
    draw = draw,
    pointerDown = pointerDown,
    pointerUp = pointerUp,
    pointerMove = pointerMove,
  }
end
