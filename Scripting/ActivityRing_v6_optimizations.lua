-- ActivityRing_v6_optimizations.lua
-- Rive Particle System explicitly designed for dynamically filling a circular bounds.
--
-- BEHAVIOR OVERVIEW:
-- This script manages a two-stage particle system that spawns from a line emitter:
-- 1. Main Particles (Inner Group): Spawn from the top emitter, fall with gravity,
--    interact fluidly, and settle compactly within the main circular boundary. Once 
--    all inner particles enter the circle, they undergo a custom relaxation phase 
--    to fill empty gaps smoothly.
-- 2. Excess Particles (Outer Group): When activeMinutes > goal, extra particles 
--    spawn from the emitter. They cascade around the outside of the main circle 
--    and pile up within an outer rectangular boundary.
--
-- PHYSICS SYSTEM:
-- Spatial hashing, grid-based squishy collisions, and boundary logic are handled 
-- by a separate module (`Physics.lua`) for optimized performance and fluid dynamics.

local Physics = require('Physics')
 
--=============================================================================
-- ACTIVITY RING SCRIPT - USAGE INSTRUCTIONS
--=============================================================================
-- To make this script work in Rive, follow these setup steps:
--
-- 1. PARTICLE ARTBOARDS (The Bubbles)
--    You need 5 separate artboards for the different particle variations.
--    Each of these 5 artboards MUST have a View Model (VM) with these properties:
--      * `type` (Number): Used to differentiate visual styling if needed.
--      * `active` (Boolean): Changed when the user taps/activates it.
--      * `pointerOver` (Boolean): True when the pointer hovers over the particle.
--
-- 2. MAIN ARTBOARD (The Sandbox)
--    Connect this script to a Custom Node in your main artboard.
--    Hook up the following Node Inputs to your Main Artboard's VM/State Machine:
--      * `artboard1` ... `artboard5`: Connect to the particle artboards.
--      * `activate` (Trigger): Optional, though VM trigger 'start' is auto-hooked.
--      * `goal` (Number): Your daily target. Dictates the size of the inner circle.
--      * `activeMinutes` (Number): Determines how many total particles to spawn.
--
-- 3. PHYSICS & TIMING PARAMETERS (Connect to Node Inputs):
--      * `gravity`: Downward pull force (e.g., 1500).
--      * `sizeMultiplier` / `secondarySizeMultiplier`: Adjust visual node sizes.
--      * `size1` / `size2`: Base inner radii depending on the spawned type.
--      * `mainCircleSize`: Forced radius of the circle (0 to allow dynamic calc).
--      * `emitterWidth` / `emitterY`: Controls the horizontal line where particles spawn.
--      * `outerBoxWidth` / `outerBoxHeight`: Rectangular boundary for excess particles.
--      * `growTime`: Time in seconds for a newly spawned particle to reach full size.
--      * `emissionInterval`: Frames to wait between each particle spawn.
--      * `packingFactor`: Controls static calculation for total required diameter.
--      * `dynamicPacking`: Controls dynamic squish/scale reduction if overcrowded.
--      * `showOutlines`: Toggle to draw debug borders (Circle, Emitter, Box).
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
  targetX: number,
  targetY: number,
  isOuter: boolean,
  escaped: boolean,
  falling: boolean,
  enteredCircle: boolean,
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
  secondarySizeMultiplier: Input<number>,
  homingForce: Input<number>,
  size1: Input<number>,
  size2: Input<number>,
  mainCircleSize: Input<number>,
  emissionInterval: Input<number>,
  growTime: Input<number>,
  outerBoxWidth: Input<number>,
  outerBoxHeight: Input<number>,
  initialSize: Input<number>,
  
  emitterWidth: Input<number>,
  emitterY: Input<number>,
  showOutlines: Input<boolean>,

  goal: Input<number>,
  activeMinutes: Input<number>,
  packingFactor: Input<number>,
  dynamicPacking: Input<number>,

  -- Graphics
  circlePath: Path,
  circlePaint: Paint,
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
  started: boolean,
  currentScale: number,
  phase: number,            -- 0: INIT, 1: EMIT_INNER, 4: EMIT_OUTER, 5: SETTLE_ALL, 6: RELAXED
  innerRelaxPhase: number,
  innerRelaxTimer: number,
  selectedParticle: Particle?,
  settleTimer: number,
  lastSpawnX: number,
  spawnDirection: number,
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
local table_insert = table.insert

local BASE_RADIUS = 10
local CELL_SIZE = 40
local SUBSTEPS = 8
local MAX_VELOCITY = 1500
local SLEEP_VELOCITY_THRESH = 30
local SLEEP_VEL_THRESH_SQ = SLEEP_VELOCITY_THRESH * SLEEP_VELOCITY_THRESH
local SLEEP_TIME_THRESH = 1.0

-- Relaxation constants
local RELAX_DURATION = 2.5        -- seconds for one full bell-curve relaxation sweep
local RELAX_MAX_INFLATION = 0.10  -- peak colRadius inflation ratio (10%) at mid-sweep
local RELAX_VEL_DAMPING = 0.88    -- per-substep velocity retention (0.88^8 ≈ 0.36/frame)
local RELAX_RESTITUTION = 0.35    -- soft collision response (vs 0.8 normal / 1.0 global)

local function cubicEaseOut(t: number): number
  return 1 - (1 - t) * (1 - t) * (1 - t)
end

-- Calculate Target Circle Radius
local function calculateCircleRadius(self: ParticleSystemNode): number
  if self.mainCircleSize and self.mainCircleSize > 0 then
    return self.mainCircleSize
  end
  local r_min = BASE_RADIUS * self.sizeMultiplier
  local area_min = mpi * r_min * r_min
  local total_area = self.goal * area_min
  return msqrt(total_area / (mpi * self.packingFactor))
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
  self.started = false
  self.currentScale = 1.0
  self.phase = 0
  self.innerRelaxPhase = 0
  self.innerRelaxTimer = 0.0
  self.selectedParticle = nil
  self.settleTimer = 0.0
  self.lastSpawnX = -999999
  self.spawnDirection = 1

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

  local inputAb: Input<Artboard<ParticleVM>>
  local targetRadius: number

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

  local isOuter = self.totalSpawned >= self.goal
  local actMultiplier = isOuter and self.secondarySizeMultiplier or self.sizeMultiplier

  targetRadius = targetRadius * actMultiplier

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

  local initSize = self.initialSize or 0.5

  local newParticle: Particle = {
    id = self.nextId,
    x = spawnX,
    y = spawnY,
    prevX = spawnX,
    prevY = spawnY,
    vx = 0,
    vy = 0,
    radius = initSize,
    originalRadius = targetRadius,
    instance = instance,
    cx = 0,
    cy = 0,
    sleeping = false,
    sleepTimer = 0,
    currentT = 0.0,
    colRadius = initSize,
    nextInCell = nil,
    type = ptType,
    bpm = ptBpm,
    targetX = 0,
    targetY = 0,
    isOuter = isOuter,
    escaped = isOuter, -- For outer, they already start escaped (i.e. outside)
    falling = true,
    enteredCircle = false,
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
      if self.phase == 6 or (not p.isOuter and self.innerRelaxPhase == 1) then
        self.selectedParticle = p
        -- Immediately snap to pointer
        p.x = pos.x
        p.y = pos.y
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
    -- Wake it up to trigger relaxation changes implicitly around it if needed
    self.selectedParticle.sleeping = false 
    event:hit()
  end
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

  local goalFloor = mfloor(self.goal)
  local totalCount = mfloor(self.activeMinutes)
  if totalCount <= 0 then
    totalCount = goalFloor
  end

  local innerTargetCount = mmin(totalCount, goalFloor)
  local outerTargetCount = mmax(0, totalCount - goalFloor)

  -- Phase transitions & Spawning Logic
  if self.phase == 0 then
    self.phase = 1 -- EMIT_INNER
  end

  if self.phase == 1 then
    if self.totalSpawned >= innerTargetCount then
      self.phase = 4 -- Jump directly to EMIT_OUTER (no pause)
      self.spawnDelayCounter = 0
    end
  end

  if self.phase == 1 or self.phase == 4 then
    local targetTotal = self.phase == 1 and innerTargetCount or (innerTargetCount + outerTargetCount)
    if self.totalSpawned >= targetTotal then
      if self.phase == 4 then
        self.phase = 5 -- SETTLE_OUTER
        self.settleTimer = 0.0
      end
    else
      if self.spawnDelayCounter <= 0 then
        spawnParticle(self, circleRadius)
        self.spawnDelayCounter = mmax(1, mfloor(self.emissionInterval))
      else
        self.spawnDelayCounter = self.spawnDelayCounter - 1
      end
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

  -- Robust Algorithm for dynamic downscaling (Accounting for Interstitial Space AND Boundary Edge Decay)
  local targetScale = 1.0
  if pCount > 0 then
    local totalRSq = 0
    local avgR = 0
    local innerCount = 0
    for i = 1, pCount do
      if not parts[i].isOuter then
        local baseR = parts[i].originalRadius
        totalRSq = totalRSq + (baseR * baseR)
        avgR = avgR + baseR
        innerCount = innerCount + 1
      end
    end
    if innerCount > 0 then
      avgR = avgR / innerCount

      local pf = self.dynamicPacking
      local R_c = circleRadius

      local A_quad = totalRSq - pf * avgR * avgR
      local B_quad = 2 * pf * R_c * avgR
      local C_quad = -pf * R_c * R_c

      local discriminant = B_quad * B_quad - 4 * A_quad * C_quad
      if discriminant >= 0 and A_quad ~= 0 then
        local optimalScale = (-B_quad + msqrt(discriminant)) / (2 * A_quad)
        if optimalScale < 1.0 then
          targetScale = optimalScale
        end
      end
    end
  end

  -- Smoothly transition the internal scale to prevent sudden jumps
  self.currentScale = self.currentScale
    + (targetScale - self.currentScale) * dt * 2.5

  local initSize = self.initialSize or 0.5

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
      -- Constantly wake up while growing
      p.sleeping = false
    end

    local easeT = cubicEaseOut(p.currentT)
    local scaledOriginal = p.originalRadius * self.currentScale
    
    if scaledOriginal > initSize then
      p.radius = initSize + (scaledOriginal - initSize) * easeT
    else
      -- If they are trying to scale smaller than initSize (rare), just force it
      p.radius = scaledOriginal
    end

    p.radius = mmax(initSize, p.radius)

    -- Update physics radius
    p.colRadius = p.radius
  end

  -- Apply smooth bell-curve inflation pressure to inner particles during relaxation.
  -- colRadius rises from 0% → RELAX_MAX_INFLATION → 0% following a sin bell over RELAX_DURATION.
  -- This creates a wave of gentle outward pressure that fills gaps without sustained jitter.
  if self.innerRelaxPhase == 1 then
    self.innerRelaxTimer = self.innerRelaxTimer + dt
    local t = mmin(1.0, self.innerRelaxTimer / RELAX_DURATION)
    local bellT = msin(t * mpi)  -- 0 → 1 → 0
    local inflation = 1.0 + RELAX_MAX_INFLATION * bellT
    for i = 1, pCount do
      local p = parts[i]
      if not p.isOuter then
        p.colRadius = p.radius * inflation
      end
    end
    -- After the full bell completes plus a short settling tail, freeze and conclude.
    if self.innerRelaxTimer >= RELAX_DURATION + 0.3 then
      self.innerRelaxPhase = 3
      for i = 1, pCount do
        if not parts[i].isOuter then
          parts[i].colRadius = parts[i].radius
          parts[i].vx = 0
          parts[i].vy = 0
          parts[i].sleeping = true
        end
      end
    end
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

  local allOuterSleeping = true
  local sumInner = 0
  local sumOuter = 0

  -- 1. Apply Forces and Integrate (Dynamic Particles only)
  -- 2. Apply Homing Forces (Relax Particles only)
  local returnSpeed = self.homingForce or 5.0
  local factor = (returnSpeed * dt) / substeps
  if factor > 1 then factor = 1 end
  local sel = self.selectedParticle
  local selId = sel and sel.id or -1

  -- Hoist variables to avoid repeated property lookups in inner loops
  local outerBoxW = self.outerBoxWidth or 600
  local outerBoxH = self.outerBoxHeight or 600

  local isGlobalRelax = self.phase >= 6
  local isInnerRelaxState = self.innerRelaxPhase == 1

  for step = 1, substeps do
    -- Integration step
    for i = 1, pCount do
      local p = parts[i]
      
      local isInnerRelax = isInnerRelaxState and not p.isOuter
      
      if isGlobalRelax then
        if p ~= sel then
          p.x = p.x + (p.targetX - p.x) * factor
          p.y = p.y + (p.targetY - p.y) * factor
        end
      elseif isInnerRelax then
        -- Carry momentum with no gravity. Particles glide smoothly into gaps;
        -- heavy per-substep damping prevents oscillation.
        p.prevX = p.x
        p.prevY = p.y
        p.x = p.x + p.vx * subDt
        p.y = p.y + p.vy * subDt
      elseif not p.sleeping then
        p.prevX = p.x
        p.prevY = p.y

        local gy = gravity * subDt
        
        if p.isOuter then
          p.escaped = true
        end

        p.vy = p.vy + gy
        p.x = p.x + p.vx * subDt
        p.y = p.y + p.vy * subDt
      end
    end

    -- Collision Solver (All particles interact within their own group in Physics.lua)
    local grid = Physics.buildGrid(parts :: { Physics.Particle }, CELL_SIZE)
    for i = 1, pCount do
      local p = parts[i]
      local isInnerRelax = isInnerRelaxState and not p.isOuter
      local restitution
      if isGlobalRelax then
        restitution = 1.0
      elseif isInnerRelax then
        restitution = RELAX_RESTITUTION  -- soft nudge, not elastic bounce
      else
        restitution = 0.8
      end
      Physics.solveCollisions(grid, p :: Physics.Particle, restitution, selId)
      
      local paddedColRad = p.colRadius
      if isInnerRelax then
         -- Use true radius for container checking so they can press up naturally against the walls
         p.colRadius = p.radius
      end
        
      if p.isOuter then
          Physics.applyCircularBoundary(
            p :: Physics.Particle,
            0,
            0,
            circleRadius,
            p.falling and 0.01 or friction,
            true
          )
          if p.falling then
            Physics.applyRectangularBoundary(
              p :: Physics.Particle,
              0,
              0,
              outerBoxW,
              outerBoxH,
              friction
            )
          end
        else
          if not p.enteredCircle then
            local distSq = p.x * p.x + p.y * p.y
            local insideThresh = circleRadius - p.colRadius
            if distSq < insideThresh * insideThresh then
              p.enteredCircle = true
            end
          end

          if p.enteredCircle and (not p.sleeping or isInnerRelaxState) then
            Physics.applyCircularBoundary(
              p :: Physics.Particle,
              0,
              0,
              circleRadius,
              friction,
              false
            )
          elseif not p.enteredCircle then
            -- Let them fall to the box boundaries until they enter
            Physics.applyRectangularBoundary(
              p :: Physics.Particle,
              0,
              0,
              outerBoxW,
              outerBoxH,
              friction
            )
          end
        end
        if isInnerRelax then
          p.colRadius = paddedColRad
        end
      end

    -- Enforce dragging specifically at end of constraints step
    if sel then
      sel.x = self.pointerPos.x
      sel.y = self.pointerPos.y
    end

    -- Velocity Update (Dynamic particles only)
    for i = 1, pCount do
      local p = parts[i]
      
      local isInnerRelax = isInnerRelaxState and not p.isOuter

      if isGlobalRelax then
        p.vx = 0
        p.vy = 0
      elseif isInnerRelax then
        -- Derive velocity from the position delta produced by collisions/constraints,
        -- then damp heavily so particles settle rather than oscillate.
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

  -- Sync prev positions for global relax (phase 6) to prevent stale velocity on next frame.
  -- Inner relax particles retain their velocity for inertia; no sync needed here.
  if isGlobalRelax then
    for i = 1, pCount do
      local p = parts[i]
      p.prevX = p.x
      p.prevY = p.y
      p.vx = 0
      p.vy = 0
    end
  end

  local allInnerEnteredCircle = true

  -- Post-physics logic and Phase Advancements
  for i = 1, pCount do
    local p = parts[i]
    local isInnerRelax = isInnerRelaxState and not p.isOuter
    local isRelaxing = isGlobalRelax or isInnerRelax
    
    if not p.isOuter then
      sumInner = sumInner + 1
      if not p.enteredCircle then
        allInnerEnteredCircle = false
      end
    end
    if p.isOuter then sumOuter = sumOuter + 1 end

    if not isRelaxing then
      -- First calculate if they've escaped cleanly (outside circleRadius plus their radius)
      if p.isOuter then
        local distSq = p.x * p.x + p.y * p.y
        local escapeThresh = circleRadius + p.colRadius
        if distSq > escapeThresh * escapeThresh then
          p.escaped = true
        end
      end

      -- If they are outer and haven't fully escaped, DO NOT ALLOW THEM TO SLEEP
      if p.isOuter and not p.escaped then
        p.sleeping = false
        p.sleepTimer = 0
      elseif not p.sleeping then
        if p.vx * p.vx + p.vy * p.vy < SLEEP_VEL_THRESH_SQ then
          p.sleepTimer = p.sleepTimer + dt
          if p.sleepTimer > SLEEP_TIME_THRESH and p.currentT >= 1.0 then
            if p.isOuter and not p.falling then
              p.falling = true
              p.sleepTimer = 0
              p.vx = 0
              p.vy = 0
            else
              p.sleeping = true
              p.vx, p.vy = 0, 0
            end
          end
        else
          p.sleepTimer = 0
        end
      end
    end
    -- Still need to evaluate sleeping status even if relaxing for phase transitions
    if p.isOuter and not p.sleeping then allOuterSleeping = false end
  end

  -- Start inner relax process when outer/inner settle begins and inner particles are ready
  -- Robust condition: Start as soon as all inner particles (based on goal) are fully inside the circle.
  if sumInner >= innerTargetCount and self.innerRelaxPhase == 0 and self.phase < 6 then
    if allInnerEnteredCircle then
      self.innerRelaxPhase = 1
      self.innerRelaxTimer = 0.0
    end
  end

  -- Phase 5: Settling Outer (and Inner together)
  if self.phase == 5 then
    self.settleTimer = self.settleTimer + dt
    -- Use a longer bailout (e.g. 20.0 seconds) for outer, to allow them to fall and stack
    -- Also bailout if inner relax phase is stuck or once it finishes
    if (sumOuter >= outerTargetCount) and (sumInner >= innerTargetCount) and (allOuterSleeping or self.settleTimer > 20.0) and (self.innerRelaxPhase >= 3) then
      for i = 1, pCount do
        local p = parts[i]
        p.targetX = p.x
        p.targetY = p.y
      end
      self.phase = 6 -- All Relaxed
      self.innerRelaxPhase = 3 -- Stop the padding logic explicitly
    end
  end

  -- Update Graphics Instances
  for i = 1, pCount do
    parts[i].instance:advance(seconds)
  end

  return true
end

local function draw(self: ParticleSystemNode, renderer: Renderer)
  local showOutlines = true
  if self.showOutlines ~= nil then
    showOutlines = self.showOutlines
  end

  if showOutlines then
    local circleRadius = calculateCircleRadius(self)
    local boxW = self.outerBoxWidth or 600
    local boxH = self.outerBoxHeight or 600
    local emitW = self.emitterWidth or 200
    local emitY = self.emitterY or -300

    -- Draw Circular Boundary Frame
    self.circlePath:reset()
    -- Approximate circle using 64-segment polygon (since :circle() may not be fully supported)
    local segments = 64
    for i = 0, segments do
      local angle = (i / segments) * mpi * 2
      local vx = mcos(angle) * circleRadius
      local vy = msin(angle) * circleRadius
      if i == 0 then
        self.circlePath:moveTo(Vector.xy(vx, vy))
      else
        self.circlePath:lineTo(Vector.xy(vx, vy))
      end
    end
    self.circlePath:close()

    renderer:drawPath(self.circlePath, self.circlePaint)

    -- Draw Outer Box
    self.boxPath:reset()
    self.boxPath:moveTo(Vector.xy(-boxW/2, -boxH/2))
    self.boxPath:lineTo(Vector.xy(boxW/2, -boxH/2))
    self.boxPath:lineTo(Vector.xy(boxW/2, boxH/2))
    self.boxPath:lineTo(Vector.xy(-boxW/2, boxH/2))
    self.boxPath:close()
    renderer:drawPath(self.boxPath, self.boxPaint)

    -- Draw Emitter Path
    self.emitterPath:reset()
    self.emitterPath:moveTo(Vector.xy(-emitW/2, emitY))
    self.emitterPath:lineTo(Vector.xy(emitW/2, emitY))
    renderer:drawPath(self.emitterPath, self.emitterPaint)
  end

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
    secondarySizeMultiplier = 1.0,
    homingForce = 5.0,
    size1 = 10,
    size2 = 10,
    mainCircleSize = 0, -- Set to > 0 to override dynamic calculation

    emissionInterval = 3,
    growTime = 0.8,
    outerBoxWidth = 600,
    outerBoxHeight = 600,
    initialSize = 0.5,
    
    emitterWidth = 200,
    emitterY = -300,

    goal = 143,
    activeMinutes = 0,
    packingFactor = 0.85,
    dynamicPacking = 0.85,
    showOutlines = true,

    activate = late(),

    circlePath = Path.new(),
    circlePaint = Paint.new(),
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
    currentScale = 1.0,
    phase = 0,
    innerRelaxPhase = 0,
    innerRelaxTimer = 0.0,
    selectedParticle = nil,
    settleTimer = 0.0,
    lastSpawnX = -999999,
    spawnDirection = 1,

    init = init,
    advance = advance,
    draw = draw,
    pointerDown = pointerDown,
    pointerUp = pointerUp,
    pointerMove = pointerMove,
  }
end 
