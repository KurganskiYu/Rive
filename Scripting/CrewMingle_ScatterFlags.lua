local Physics = require('Physics')

--=============================================================================
-- FLAGS SCATTER SCRIPT
--=============================================================================

local COUNTRY_CODES = {
  "US", "GB", "AU", "CA", "DE", "FR", "JP", "IT", "BR", "IN",
  "CN", "RU", "KR", "ES", "MX", "ID", "NL", "SA", "CH", "AR",
  "SE", "PL", "BE", "TH", "ZA"
}

type ParticleVM = {
  countryCode: Property<string>,
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
  radius: number,
  originalRadius: number,
  instance: Artboard<ParticleVM>,
  sleepTimer: number,
  currentT: number,
  isOuter: boolean,
  settledX: number,
  settledY: number,
}

type ParticleSystemNode = {
  artboard: Input<Artboard<ParticleVM>>,
  activate: Input<Trigger>,
  countriesNum: Input<number>,

  friction: Input<number>,
  damping: Input<number>,
  attractionForce: Input<number>,
  collisionStiffness: Input<number>,
  
  baseParticleSize: Input<number>,
  initialSizeMultiplier: Input<number>,
  finalSizeMultiplier: Input<number>,
  relaxRadiusMultiplier: Input<number>,
  
  growTime: Input<number>,
  pauseTime: Input<number>,
  relaxTime: Input<number>,
  
  boxWidth: Input<number>,
  boxHeight: Input<number>,
  
  emitterWidth: Input<number>,
  emitterHeight: Input<number>,
  emitterX: Input<number>,
  emitterY: Input<number>,
  initialSpeed: Input<number>,
  
  emissionInterval: Input<number>,
  showOutlines: Input<boolean>,

  boxPath: Path,
  boxPaint: Paint,
  emitterPath: Path,
  emitterPaint: Paint,

  _particles: { Particle },
  mat: Mat2D,
  nextId: number,
  totalSpawned: number,
  spawnDelayCounter: number,
  pointerPos: { x: number, y: number },
  started: boolean,
  
  phase: number,            -- 0: INIT, 1: EMIT, 2: PAUSE, 3: SPREAD_RELAX, 4: SETTLED
  pauseTimer: number,
  relaxTimer: number,
  selectedParticle: Particle?,
  activationIndex: number,
  activationDelayCounter: number,
}

local activate: (self: ParticleSystemNode) -> ()

local mfloor = math.floor
local mmax = math.max
local mmin = math.min
local mrandom = math.random
local msqrt = math.sqrt
local mcos = math.cos
local msin = math.sin
local mpi = math.pi
local matan2 = math.atan2
local table_insert = table.insert

local BASE_RADIUS = 10
local CELL_SIZE = 100
local SUBSTEPS = 8
local MAX_VELOCITY = 1500
local SLEEP_VELOCITY_THRESH = 30
local SLEEP_VEL_THRESH_SQ = SLEEP_VELOCITY_THRESH * SLEEP_VELOCITY_THRESH
local SLEEP_TIME_THRESH = 1.0

local RELAX_DURATION = 3.0
local RELAX_VEL_DAMPING = 0.88    
local RELAX_RESTITUTION = 0.35    

local function cubicEaseOut(t: number): number
  return 1 - (1 - t) * (1 - t) * (1 - t)
end

local function init(self: ParticleSystemNode, context: Context): boolean
  local vm = context:viewModel()
  if vm then
    local startTrigger = vm:getTrigger('start')
    if startTrigger then
      startTrigger:addListener(function()
        activate(self)
      end)
    end
  end

  self.boxPath = Path.new()
  self.boxPaint = Paint.with({ style = 'stroke', color = 0x40FFFFFF, thickness = 2.0 })

  self.emitterPath = Path.new()
  self.emitterPaint = Paint.with({ style = 'stroke', color = 0x80FF0000, thickness = 2.0 })

  self._particles = {}
  self.mat = Mat2D.identity()
  self.nextId = 1
  self.totalSpawned = 0
  self.spawnDelayCounter = 0
  self.pointerPos = { x = 0, y = 0 }
  
  -- Automatically start the emitter if no external trigger is hit, 
  -- ensuring it works immediately upon preview
  self.started = true
  self.phase = 0
  self.pauseTimer = 0.0
  self.relaxTimer = 0.0
  self.selectedParticle = nil
  self.activationIndex = 1
  self.activationDelayCounter = 0

  math.randomseed(os.time())
  return true
end

activate = function(self: ParticleSystemNode)
  self.started = true
end

local function spawnParticle(self: ParticleSystemNode)
  if not self.artboard then return end -- Failsafe check
  local instance = self.artboard:instance()
  if not instance then return end
  
  instance:advance(0)

  local randCode = COUNTRY_CODES[mrandom(1, #COUNTRY_CODES)]
  if instance.data then
    if instance.data.countryCode then
      instance.data.countryCode.value = randCode
    end
    if instance.data.active then
      instance.data.active.value = false
    end
    if instance.data.pointerOver then
      instance.data.pointerOver.value = false
    end
  end

  local ex = self.emitterX or 0
  local ey = self.emitterY or -300
  local ew = self.emitterWidth or 200
  local eh = self.emitterHeight or 200

  local spawnX = ex + (mrandom() - 0.5) * ew
  local spawnY = ey + (mrandom() - 0.5) * eh

  local angle = matan2(spawnY - ey, spawnX - ex)
  local speed = self.initialSpeed or 100
  local initVx = mcos(angle) * speed
  local initVy = msin(angle) * speed

  local baseSize = self.baseParticleSize or 30
  local targetRadius = baseSize * (self.finalSizeMultiplier or 1.0)
  local initSize = baseSize * (self.initialSizeMultiplier or 0.0)

  local newParticle: Particle = {
    id = self.nextId,
    x = spawnX,
    y = spawnY,
    prevX = spawnX,
    prevY = spawnY,
    vx = initVx,
    vy = initVy,
    radius = initSize,
    originalRadius = targetRadius,
    instance = instance,
    cx = 0, cy = 0,
    sleeping = false,
    sleepTimer = 0,
    currentT = 0.0,
    colRadius = initSize,
    nextInCell = nil,
    isOuter = false,
    settledX = spawnX,
    settledY = spawnY,
  }

  table_insert(self._particles, newParticle)
  self.nextId = self.nextId + 1
  self.totalSpawned = self.totalSpawned + 1
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
      if p.instance.data and p.instance.data.active then
        p.instance.data.active.value = not p.instance.data.active.value
      end
      self.selectedParticle = p
      p.x = pos.x
      p.y = pos.y
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
  if not self.started then return true end

  local dt = mmin(seconds, 0.05)
  local targetCount = mmax(1, mfloor(self.countriesNum or 25))

  if self.phase == 0 then
    self.phase = 1 -- EMIT
  end

  if self.phase == 1 then
    if self.totalSpawned >= targetCount then
      self.phase = 2 -- PAUSE
      self.pauseTimer = 0.0
    else
      if self.spawnDelayCounter <= 0 then
        spawnParticle(self)
        self.spawnDelayCounter = mmax(1, mfloor(self.emissionInterval or 3))
      else
        self.spawnDelayCounter = self.spawnDelayCounter - 1
      end
    end
  end
  
  if self.phase == 2 then
    self.pauseTimer = self.pauseTimer + dt
    if self.pauseTimer >= (self.pauseTime or 1.0) then
      self.phase = 3 -- SPREAD_RELAX
      self.relaxTimer = 0.0
    end
  end

  local parts = self._particles
  local pCount = #parts
  if pCount == 0 then return true end

  local growDur = mmax(0.01, self.growTime or 0.8)
  local changeSpeed = dt / growDur
  local px, py = self.pointerPos.x, self.pointerPos.y
  local baseSize = self.baseParticleSize or 30
  local initSize = baseSize * (self.initialSizeMultiplier or 0.0)

  local isRelaxState = self.phase == 3
  local relaxMult = self.relaxRadiusMultiplier or 1.5
  local currentRelaxMult = 1.0

  if self.phase >= 3 then
    if self.activationIndex <= pCount then
      if self.activationDelayCounter <= 0 then
        local p = parts[self.activationIndex]
        if p.instance.data and p.instance.data.active then
          p.instance.data.active.value = true
        end
        self.activationIndex = self.activationIndex + 1
        self.activationDelayCounter = mmax(1, mfloor(self.emissionInterval or 3))
      else
        self.activationDelayCounter = self.activationDelayCounter - 1
      end
    end
  end

  if isRelaxState then
    self.relaxTimer = self.relaxTimer + dt
    local rTime = self.relaxTime or 3.0
    local t = mmin(1.0, self.relaxTimer / rTime)
    
    -- Bell curve (0 -> 1 -> 0) to push them apart smoothly and then let them settle back slightly
    local bellT = msin(t * mpi) 
    currentRelaxMult = 1.0 + (relaxMult - 1.0) * bellT
    
    if self.relaxTimer >= rTime + 0.3 then
      self.phase = 4 -- SETTLED
      for i = 1, pCount do
        parts[i].colRadius = parts[i].radius
        parts[i].vx = 0
        parts[i].vy = 0
        parts[i].sleeping = true
        parts[i].settledX = parts[i].x
        parts[i].settledY = parts[i].y
      end
    end
  end

  for i = 1, pCount do
    local p = parts[i]

    if p.instance.data and p.instance.data.pointerOver then
      local dx = p.x - px
      local dy = p.y - py
      local isOver = (dx * dx + dy * dy) <= (p.radius * p.radius)
      if p.instance.data.pointerOver.value ~= isOver then
        p.instance.data.pointerOver.value = isOver
      end
    end

    if p.currentT < 1.0 then
      p.currentT = mmin(1.0, p.currentT + changeSpeed)
      p.sleeping = false
    end

    local easeT = cubicEaseOut(p.currentT)
    local scaledOriginal = p.originalRadius
    
    if scaledOriginal > initSize then
      p.radius = initSize + (scaledOriginal - initSize) * easeT
    else
      p.radius = scaledOriginal
    end
    p.radius = mmax(initSize, p.radius)
    
    if isRelaxState then
      p.colRadius = p.radius * currentRelaxMult
    else
      p.colRadius = p.radius
    end
  end

  local substeps = SUBSTEPS
  local subDt = mmin(dt / substeps, 0.01)
  local attractionForce = self.attractionForce or 1500
  local friction = self.friction or 0.5
  
  -- Remap damping to be more intuitive (0.0 to 1.0 range in Rive Editor)
  -- 0 means no damping (multiplier = 1.0)
  -- 1 means strong damping (multiplier = 0.9)
  local inputDamping = mmax(0, mmin(1, self.damping or 0.15))
  local damping = 1.0 - (inputDamping * 0.1)
  
  local sel = self.selectedParticle
  local selId = sel and sel.id or -1

  local boxW = self.boxWidth or 600
  local boxH = self.boxHeight or 600
  local emitX = self.emitterX or 0
  local emitY = self.emitterY or -300

  for step = 1, substeps do
    for i = 1, pCount do
      local p = parts[i]
      
      if self.phase == 4 and p ~= sel then
         -- Slight spring effect
         p.prevX = p.x
         p.prevY = p.y
         
         local dx = p.settledX - p.x
         local dy = p.settledY - p.y
         
         local springK = 200
         local springDamp = 25
         
         p.vx = p.vx + (dx * springK - p.vx * springDamp) * subDt
         p.vy = p.vy + (dy * springK - p.vy * springDamp) * subDt
         
         p.x = p.x + p.vx * subDt
         p.y = p.y + p.vy * subDt
      elseif not p.sleeping then
        p.prevX = p.x
        p.prevY = p.y
        
        local dx = emitX - p.x
        local dy = emitY - p.y
        local dist = msqrt(dx * dx + dy * dy)
        if dist > 0.001 then
          p.vx = p.vx + (dx / dist) * attractionForce * subDt
          p.vy = p.vy + (dy / dist) * attractionForce * subDt
        end
        
        p.x = p.x + p.vx * subDt
        p.y = p.y + p.vy * subDt
      end
    end

    local grid = Physics.buildGrid(parts :: { Physics.Particle }, CELL_SIZE)
    
    -- Remap collisionStiffness (0.0 to 1.0 range in Rive Editor)
    -- Using a quadratic mapping so it feels more responsive while still dropping low
    local inputStiff = mmax(0, mmin(1, self.collisionStiffness or 0.1))
    local mappedStiffness = inputStiff * inputStiff

    
    for i = 1, pCount do
      local p = parts[i]
      
      -- ParticlePhysics17 tight fill logic: override stiffness completely with 1.0 when relaxing/settled!
      local isInteractingOrSettled = (self.phase >= 3)
      local stiffness = isInteractingOrSettled and 1.0 or mappedStiffness
      
      Physics.solveCollisions(grid, p :: Physics.Particle, stiffness, selId)
      
      local paddedColRad = p.colRadius
      if isRelaxState then
         p.colRadius = p.radius
      end
      
      Physics.applyRectangularBoundary(p :: Physics.Particle, 0, 0, boxW, boxH, friction)
      
      if isRelaxState then
        p.colRadius = paddedColRad
      end
    end

    if sel then
      sel.x = self.pointerPos.x
      sel.y = self.pointerPos.y
    end

    for i = 1, pCount do
      local p = parts[i]
      if self.phase == 4 and p ~= sel then
        local vx = (p.x - p.prevX) / subDt
        local vy = (p.y - p.prevY) / subDt
        p.vx = vx * damping 
        p.vy = vy * damping
      elseif isRelaxState then
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

  for i = 1, pCount do
    local p = parts[i]
    if self.phase <= 3 and not p.sleeping then
      if p.vx * p.vx + p.vy * p.vy < SLEEP_VEL_THRESH_SQ then
        p.sleepTimer = p.sleepTimer + dt
        if p.sleepTimer > SLEEP_TIME_THRESH and p.currentT >= 1.0 then
          p.sleeping = true
          p.vx, p.vy = 0, 0
        end
      else
        p.sleepTimer = 0
      end
    end
    p.instance:advance(seconds)
  end

  return true
end

local function draw(self: ParticleSystemNode, renderer: Renderer)
  local showOutlines = self.showOutlines == nil and true or self.showOutlines

  if showOutlines then
    local boxW = self.boxWidth or 600
    local boxH = self.boxHeight or 600
    local emitW = self.emitterWidth or 200
    local emitH = self.emitterHeight or 200
    local emitX = self.emitterX or 0
    local emitY = self.emitterY or -300

    self.boxPath:reset()
    self.boxPath:moveTo(Vector.xy(-boxW/2, -boxH/2))
    self.boxPath:lineTo(Vector.xy(boxW/2, -boxH/2))
    self.boxPath:lineTo(Vector.xy(boxW/2, boxH/2))
    self.boxPath:lineTo(Vector.xy(-boxW/2, boxH/2))
    self.boxPath:close()
    renderer:drawPath(self.boxPath, self.boxPaint)

    self.emitterPath:reset()
    self.emitterPath:moveTo(Vector.xy(emitX - emitW/2, emitY - emitH/2))
    self.emitterPath:lineTo(Vector.xy(emitX + emitW/2, emitY - emitH/2))
    self.emitterPath:lineTo(Vector.xy(emitX + emitW/2, emitY + emitH/2))
    self.emitterPath:lineTo(Vector.xy(emitX - emitW/2, emitY + emitH/2))
    self.emitterPath:close()
    renderer:drawPath(self.emitterPath, self.emitterPaint)
  end

  local parts = self._particles
  if not parts then return end

  local mat = self.mat
  local baseSize = self.baseParticleSize or 30
  for i = 1, #parts do
    local p = parts[i]
    renderer:save()
    local scale = p.radius / baseSize
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
    artboard = late(),
    activate = late(),
    countriesNum = 25,

    friction = 0.5,
    damping = 0.15,
    attractionForce = 1500,
    collisionStiffness = 0.1,
    
    baseParticleSize = 30,
    initialSizeMultiplier = 0.0,
    finalSizeMultiplier = 1.0,
    relaxRadiusMultiplier = 1.5,
    
    growTime = 0.8,
    pauseTime = 1.0,
    relaxTime = 3.0,
    
    boxWidth = 600,
    boxHeight = 600,
    
    emitterWidth = 200,
    emitterHeight = 200,
    emitterX = 0,
    emitterY = -300,
    initialSpeed = 100,
    
    emissionInterval = 3,
    growTime = 0.8,
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

    started = false,
    phase = 0,
    pauseTimer = 0.0,
    relaxTimer = 0.0,
    selectedParticle = nil,
    activationIndex = 1,
    activationDelayCounter = 0,

    init = init,
    advance = advance,
    draw = draw,
    pointerDown = pointerDown,
    pointerUp = pointerUp,
    pointerMove = pointerMove,
  }
end 
