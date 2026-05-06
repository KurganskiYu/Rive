local Physics = require('Physics')

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
  radius: number,
  colRadius: number,
  sleeping: boolean,
  instance: Artboard<ParticleVM>,
  sleepTimer: number,
}

type ParticleSystemNode = {
  -- Inputs
  particleArtboard: Input<Artboard<ParticleVM>>,

  friction: Input<number>,
  damping: Input<number>,
  gravity: Input<number>,
  baseRadius: Input<number>,
  scaleVariation: Input<number>,
  emissionInterval: Input<number>,
  boxWidth: Input<number>,
  boxHeight: Input<number>,
  particleCount: Input<number>,
  
  emitterWidth: Input<number>,
  emitterY: Input<number>,
  showOutlines: Input<boolean>,

  -- Graphics
  boxPath: Path,
  boxPaint: Paint,
  emitterPath: Path,
  emitterPaint: Paint,

  -- State
  _particles: { Particle },
  mat: Mat2D,
  nextId: number,
  totalSpawned: number,
  spawnDelayCounter: number,
  pointerPos: { x: number, y: number },
  phase: number,            -- 0: EMIT, 1: SETTLE, 2: RELAXED
  relaxTimer: number,
  selectedParticle: Particle?,
  lastSpawnX: number,
  spawnDirection: number,
  counterProp: Property<number>?,
}

local mfloor = math.floor
local mmax = math.max
local mmin = math.min
local mrandom = math.random

local CELL_SIZE = 40
local SUBSTEPS = 8
local MAX_VELOCITY = 1500
local SLEEP_VELOCITY_THRESH = 30
local SLEEP_VEL_THRESH_SQ = SLEEP_VELOCITY_THRESH * SLEEP_VELOCITY_THRESH
local SLEEP_TIME_THRESH = 1.0

-- Relaxation constants
local RELAX_DURATION = 2.5
local RELAX_MAX_INFLATION = 0.10
local RELAX_VEL_DAMPING = 0.88
local RELAX_RESTITUTION = 0.35

local function init(self: ParticleSystemNode, context: Context): boolean
  local vm = context:viewModel()
  if vm then
    self.counterProp = vm:getNumber("counter")
  end

  self.boxPath = Path.new()
  self.boxPaint = Paint.with({
    style = 'stroke',
    color = 0x40FFFFFF,
    thickness = 2.0,
  })

  self.emitterPath = Path.new()
  self.emitterPaint = Paint.with({
    style = 'stroke',
    color = 0x80FF0000,
    thickness = 2.0,
  })

  self._particles = {}
  self.mat = Mat2D.identity()
  self.nextId = 1
  self.totalSpawned = 0
  self.spawnDelayCounter = 0
  self.pointerPos = { x = 0, y = 0 }
  
  self.phase = 0
  self.relaxTimer = 0.0
  self.selectedParticle = nil
  self.lastSpawnX = -999999
  self.spawnDirection = 1

  math.randomseed(os.time())
  return true
end

local function spawnParticle(self: ParticleSystemNode)
  local instance = self.particleArtboard:instance()
  if not instance then return end

  local baseRad = self.baseRadius or 10
  local scaleVar = self.scaleVariation or 0.5
  local radTarget = baseRad + (baseRad * (mrandom() * scaleVar))

  instance:advance(0)

  local spawnY = self.emitterY or -300
  local width = self.emitterWidth or 200
  local halfWidth = width / 2

  if self.lastSpawnX == -999999 then 
    self.lastSpawnX = -halfWidth 
  end

  local spawnX = self.lastSpawnX
  if self.spawnDirection == 1 then
    spawnX = spawnX + mrandom(10, 25)
    if spawnX > halfWidth then
      spawnX = halfWidth
      self.spawnDirection = -1
    end
  else
    spawnX = spawnX - mrandom(10, 25)
    if spawnX < -halfWidth then
      spawnX = -halfWidth
      self.spawnDirection = 1
    end
  end
  self.lastSpawnX = spawnX

  local newParticle: Particle = {
    id = self.nextId,
    x = spawnX,
    y = spawnY,
    prevX = spawnX,
    prevY = spawnY,
    vx = 0,
    vy = 0,
    radius = radTarget,
    colRadius = radTarget,
    instance = instance,
    sleeping = false,
    sleepTimer = 0,
  }

  table.insert(self._particles, newParticle)
  self.nextId = self.nextId + 1
  self.totalSpawned = self.totalSpawned + 1

  if self.counterProp then
    self.counterProp.value = self.totalSpawned
  end
end

local function pointerDown(self: ParticleSystemNode, event: PointerEvent)
  local parts = self._particles
  if not parts then return end
  local pos = event.position
  self.pointerPos.x = pos.x
  self.pointerPos.y = pos.y
  
  for i = #parts, 1, -1 do
    local p = parts[i]
    local dx = pos.x - p.x
    local dy = pos.y - p.y
    if dx * dx + dy * dy <= p.radius * p.radius then
      if self.phase == 2 or self.phase == 1 then
        self.selectedParticle = p
        p.x = pos.x
        p.y = pos.y
        p.sleeping = false
      end
      event:hit()
      return
    end
  end
end

local function pointerUp(self: ParticleSystemNode, event: PointerEvent)
  if self.selectedParticle then
    self.selectedParticle = nil
  end
end

local function pointerMove(self: ParticleSystemNode, event: PointerEvent)
  local pos = event.position
  self.pointerPos.x = pos.x
  self.pointerPos.y = pos.y
  
  if self.selectedParticle then
    self.selectedParticle.x = pos.x
    self.selectedParticle.y = pos.y
    self.selectedParticle.sleeping = false 
    event:hit()
  end
end

local function advance(self: ParticleSystemNode, seconds: number): boolean
  local dt = seconds
  if dt > 0.05 then dt = 0.05 end

  local targetCount = mfloor(self.particleCount or 50)
  local emissionInt = self.emissionInterval or 3

  -- Phase transitions & Spawning Logic
  if self.phase == 0 then
    if self.totalSpawned >= targetCount then
      self.phase = 1 -- SETTLE
      self.relaxTimer = 0.0
    else
      if self.spawnDelayCounter <= 0 then
        spawnParticle(self)
        self.spawnDelayCounter = mmax(1, mfloor(emissionInt))
      else
        self.spawnDelayCounter = self.spawnDelayCounter - 1
      end
    end
  end 

  local parts = self._particles
  local pCount = #parts
  if pCount == 0 then return true end

  local isRelaxPhase = false
  local allSleeping = true

  -- Determine Phase 2: Relaxed
  if self.phase == 1 then
    for i = 1, pCount do
      if not parts[i].sleeping then
        allSleeping = false
        break
      end
    end
    if allSleeping then
      self.phase = 2
      self.relaxTimer = 0.0
    end
  end

  if self.phase == 2 then
    isRelaxPhase = true
    self.relaxTimer = self.relaxTimer + dt
  end

  if isRelaxPhase and self.relaxTimer <= RELAX_DURATION + 0.3 then
    local t = mmin(1.0, self.relaxTimer / RELAX_DURATION)
    local bellT = math.sin(t * math.pi)
    local inflation = 1.0 + RELAX_MAX_INFLATION * bellT
    for i = 1, pCount do
        parts[i].colRadius = parts[i].radius * inflation
    end
  elseif self.phase == 2 and self.relaxTimer > RELAX_DURATION + 0.3 then
     for i = 1, pCount do
        parts[i].colRadius = parts[i].radius
    end
    isRelaxPhase = false
  end

  local substeps = SUBSTEPS
  local subDt = dt / substeps
  local gravity = self.gravity or 1500
  local friction = self.friction or 0.5
  local damping = self.damping or 0.985

  if subDt > 0.01 then
    subDt = 0.01
  end

  local sel = self.selectedParticle
  local selId = sel and sel.id or -1
  local boxW = self.boxWidth or 600
  local boxH = self.boxHeight or 600

  for step = 1, substeps do
    -- Integration
    for i = 1, pCount do
      local p = parts[i]
      if isRelaxPhase then
        p.prevX = p.x
        p.prevY = p.y
        p.x = p.x + p.vx * subDt
        p.y = p.y + p.vy * subDt
      elseif not p.sleeping then
        p.prevX = p.x
        p.prevY = p.y
        p.vy = p.vy + (gravity * subDt)
        p.x = p.x + p.vx * subDt
        p.y = p.y + p.vy * subDt
      end
    end

    -- Collisions
    local grid = Physics.buildGrid(parts :: any, CELL_SIZE)
    for i = 1, pCount do
      local p = parts[i]
      local restitution = isRelaxPhase and RELAX_RESTITUTION or 0.8
      Physics.solveCollisions(grid, p :: any, restitution, selId)
      
      local colRadBackup = p.colRadius
      if isRelaxPhase then p.colRadius = p.radius end
      
      Physics.applyRectangularBoundary(
         p :: any,
         0, 0,
         boxW, boxH,
         friction
      )
      
      if isRelaxPhase then p.colRadius = colRadBackup end
    end

    if sel then
      sel.x = self.pointerPos.x
      sel.y = self.pointerPos.y
    end

    -- Velocity update
    for i=1, pCount do
      local p = parts[i]
      if isRelaxPhase then
        local vx = (p.x - p.prevX) / subDt
        local vy = (p.y - p.prevY) / subDt
        p.vx = vx * RELAX_VEL_DAMPING
        p.vy = vy * RELAX_VEL_DAMPING
      elseif not p.sleeping then
        local vx = (p.x - p.prevX) / subDt * damping
        local vy = (p.y - p.prevY) / subDt * damping
        if vx > MAX_VELOCITY then vx = MAX_VELOCITY elseif vx < -MAX_VELOCITY then vx = -MAX_VELOCITY end
        if vy > MAX_VELOCITY then vy = MAX_VELOCITY elseif vy < -MAX_VELOCITY then vy = -MAX_VELOCITY end
        p.vx = vx
        p.vy = vy
      end
    end
  end

  -- Sleeping logic
  for i = 1, pCount do
    local p = parts[i]
    if not isRelaxPhase then
      if not p.sleeping then
        if p.vx * p.vx + p.vy * p.vy < SLEEP_VEL_THRESH_SQ then
          p.sleepTimer = p.sleepTimer + dt
          if p.sleepTimer > SLEEP_TIME_THRESH then
            p.sleeping = true
            p.vx, p.vy = 0, 0
          end
        else
          p.sleepTimer = 0
        end
      end
    end
    p.instance:advance(seconds)
  end

  return true
end

local function draw(self: ParticleSystemNode, renderer: Renderer)
  if self.showOutlines then
    local boxW = self.boxWidth or 600
    local boxH = self.boxHeight or 600
    local emitW = self.emitterWidth or 200
    local emitY = self.emitterY or -300

    self.boxPath:reset()
    self.boxPath:moveTo(Vector.xy(-boxW/2, -boxH/2))
    self.boxPath:lineTo(Vector.xy(boxW/2, -boxH/2))
    self.boxPath:lineTo(Vector.xy(boxW/2, boxH/2))
    self.boxPath:lineTo(Vector.xy(-boxW/2, boxH/2))
    self.boxPath:close()
    renderer:drawPath(self.boxPath, self.boxPaint)

    self.emitterPath:reset()
    self.emitterPath:moveTo(Vector.xy(-emitW/2, emitY))
    self.emitterPath:lineTo(Vector.xy(emitW/2, emitY))
    renderer:drawPath(self.emitterPath, self.emitterPaint)
  end

  local parts = self._particles
  if not parts then return end

  local mat = self.mat
  for i = 1, #parts do
    local p = parts[i]
    renderer:save()
    local baseR = self.baseRadius or 10
    local scale = p.radius / baseR -- Mapped safely instead of hardcoded 10
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
    particleArtboard = late(),
    friction = 0.5,
    damping = 0.985,
    gravity = 1500,
    baseRadius = 10,
    scaleVariation = 0.5,
    particleCount = 50,
    emissionInterval = 3,
    
    boxWidth = 600,
    boxHeight = 600,
    emitterWidth = 200,
    emitterY = -300,
    showOutlines = true,

    boxPath = Path.new(),
    boxPaint = Paint.new(),
    emitterPath = Path.new(),
    emitterPaint = Paint.new(),

    _particles = {},
    mat = Mat2D.identity(),

    nextId = 1,
    totalSpawned = 0,
    spawnDelayCounter = 0,
    pointerPos = { x = 0, y = 0 },

    phase = 0,
    relaxTimer = 0.0,
    selectedParticle = nil,
    lastSpawnX = -999999,
    spawnDirection = 1,
    counterProp = nil,

    init = init,
    advance = advance,
    draw = draw,
    pointerDown = pointerDown,
    pointerUp = pointerUp,
    pointerMove = pointerMove,
  }
end
