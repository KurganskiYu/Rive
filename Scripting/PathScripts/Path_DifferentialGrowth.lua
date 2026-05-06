-- Differential Line Growth Modifier
-- Simulates organic growth using iterative resampling, relaxation, and repulsion forces.

type Point = {
  x: number,
  y: number,
  fx: number, -- Force X accumulation
  fy: number, -- Force Y accumulation
  newX: number, -- Temp position for verlet/integration
  newY: number
}

type DifferentialGrowth = {
  -- Parameters
  growthCenter: Input<number>, -- 0-100%
  growthWidth: Input<number>,  -- 0-100%
  duration: Input<number>,     -- Seconds
  processEveryNFrames: Input<number>, -- Throttles simulation speed
  targetSegmentLength: Input<number>,
  repulsionRadius: Input<number>,
  repulsionStrength: Input<number>, 
  attractionStrength: Input<number>, -- Spring stiffness for neighbors
  growthSpeed: Input<number>,  -- Expansion force
  noiseAmplitude: Input<number>, -- Initial chaotic displacement

  -- State
  time: number,
  frameCount: number,
  nodes: {Point}, -- List of points
  isInitialized: boolean,
  isClosed: boolean, -- Whether the source path is a closed contour
  context: Context,
  
  -- Methods
  noise: (self: DifferentialGrowth, x: number, y: number) -> number,
  initFromPath: (self: DifferentialGrowth, path: PathData) -> (),
  simulate: (self: DifferentialGrowth, dt: number) -> (),
}

local function length(x: number, y: number): number
  return math.sqrt(x * x + y * y)
end

local function distSq(x1: number, y1: number, x2: number, y2: number): number
  local dx = x1 - x2
  local dy = y1 - y2
  return dx*dx + dy*dy
end

local function pointsClose(x1: number, y1: number, x2: number, y2: number): boolean
  return distSq(x1, y1, x2, y2) <= 1e-4
end

local function normalize(x: number, y: number): (number, number)
  local l = length(x, y)
  if l > 0.0001 then return x / l, y / l end
  return 0, 0
end

-- Math & Noise Helpers
local mfloor = math.floor
local msin = math.sin
local mcos = math.cos
local twopi = 6.28318530718

local function randomGradient(ix: number, iy: number): (number, number)
    local random = msin(ix * 12.9898 + iy * 78.233) * 43758.5453
    local val = random - mfloor(random)
    local angle = val * twopi
    return mcos(angle), msin(angle)
end

local function dotGridGradient(ix: number, iy: number, dx: number, dy: number): number
    local gx, gy = randomGradient(ix, iy)
    return gx * dx + gy * dy
end

local function perlin2D(x: number, y: number): number
    local x0 = mfloor(x)
    local y0 = mfloor(y)
    local x1 = x0 + 1
    local y1 = y0 + 1

    local dx0 = x - x0
    local dy0 = y - y0
    local dx1 = dx0 - 1
    local dy1 = dy0 - 1
    
    local sx = dx0 * dx0 * dx0 * (dx0 * (dx0 * 6 - 15) + 10)
    local sy = dy0 * dy0 * dy0 * (dy0 * (dy0 * 6 - 15) + 10)
    
    local n0 = dotGridGradient(x0, y0, dx0, dy0)
    local n1 = dotGridGradient(x1, y0, dx1, dy0)
    local ix0 = n0 + sx * (n1 - n0)

    n0 = dotGridGradient(x0, y1, dx0, dy1)
    n1 = dotGridGradient(x1, y1, dx1, dy1)
    local ix1 = n0 + sx * (n1 - n0)

    return ix0 + sy * (ix1 - ix0)
end

-- Bezier Helpers
local function cubicAt(t: number, x0: number, y0: number, x1: number, y1: number, x2: number, y2: number, x3: number, y3: number): (number, number)
    local u = 1 - t
    local tt = t * t
    local uu = u * u
    local uuu = uu * u
    local ttt = tt * t
    
    local x = uuu * x0 + 3 * uu * t * x1 + 3 * u * tt * x2 + ttt * x3
    local y = uuu * y0 + 3 * uu * t * y1 + 3 * u * tt * y2 + ttt * y3
    return x, y
end

local function quadAt(t: number, x0: number, y0: number, x1: number, y1: number, x2: number, y2: number): (number, number)
    local u = 1 - t
    local tt = t * t
    local uu = u * u
    
    local x = uu * x0 + 2 * u * t * x1 + tt * x2
    local y = uu * y0 + 2 * u * t * y1 + tt * y2
    return x, y
end

function noise(self: DifferentialGrowth, x: number, y: number): number
  return perlin2D(x, y)
end

-- Initialization: Sample the path and apply initial noise
function initFromPath(self: DifferentialGrowth, path: PathData)
    self.nodes = {}
    local tempNodes: {Point} = {}

    self.isClosed = false
    local firstX, firstY = 0, 0
    local haveFirst = false
    local lastCommandWasClose = false
    
    -- 1. Flatten path into points
    local lastX, lastY = 0, 0
    local sampleDist = math.max(1, self.targetSegmentLength)
    
    for i = 1, #path do
        local cmd = path[i]
        if cmd.type == 'moveTo' then
            lastX, lastY = cmd[1].x, cmd[1].y
            if not haveFirst then
                firstX, firstY = lastX, lastY
                haveFirst = true
            end
            local point: Point = {x=lastX, y=lastY, fx=0, fy=0, newX=0, newY=0}
            table.insert(tempNodes, point)
            lastCommandWasClose = false
        elseif cmd.type == 'lineTo' then
            local pt = cmd[1]
            local d = length(pt.x - lastX, pt.y - lastY)
            local steps = math.ceil(d / sampleDist)
            for s = 1, steps do
                local t = s / steps
                local point: Point = {
                    x = lastX + (pt.x - lastX) * t,
                    y = lastY + (pt.y - lastY) * t,
                    fx=0, fy=0, newX=0, newY=0
                }
                table.insert(tempNodes, point)
            end
            lastX, lastY = pt.x, pt.y
            lastCommandWasClose = false
        elseif cmd.type == 'cubicTo' then
             local cp1 = cmd[1]
             local cp2 = cmd[2]
             local ep = cmd[3]
             -- Estimate arc length roughly
             local chord = length(ep.x - lastX, ep.y - lastY)
             local steps = math.ceil(chord / sampleDist * 1.5)
             
             for s = 1, steps do
                local t = s / steps
                local bx, by = cubicAt(t, lastX, lastY, cp1.x, cp1.y, cp2.x, cp2.y, ep.x, ep.y)
                 local point: Point = {
                    x = bx, y = by, fx=0, fy=0, newX=0, newY=0
                }
                table.insert(tempNodes, point)
             end
             lastX, lastY = ep.x, ep.y
             lastCommandWasClose = false
        elseif cmd.type == 'quadTo' then
             local cp = cmd[1]
             local ep = cmd[2]
             local chord = length(ep.x - lastX, ep.y - lastY)
             local steps = math.ceil(chord / sampleDist * 1.2)
             for s = 1, steps do
                local t = s / steps
                 local bx, by = quadAt(t, lastX, lastY, cp.x, cp.y, ep.x, ep.y)
                 local point: Point = {
                    x = bx, y = by, fx=0, fy=0, newX=0, newY=0
                }
                table.insert(tempNodes, point)
             end
             lastX, lastY = ep.x, ep.y
             lastCommandWasClose = false
        elseif cmd.type == 'close' then
            -- Rive paths can include an explicit close command
            self.isClosed = true
            lastCommandWasClose = true
        end
    end

    -- If the path endpoints coincide, treat it as closed even without an explicit close()
    if not self.isClosed and haveFirst and #tempNodes > 1 then
        local last = tempNodes[#tempNodes]
        if pointsClose(firstX, firstY, last.x, last.y) then
            self.isClosed = true
        end
    end

    -- If closed, remove duplicated last point that equals first to avoid a zero-length segment
    if self.isClosed and #tempNodes > 2 then
        local first = tempNodes[1]
        local last = tempNodes[#tempNodes]
        if pointsClose(first.x, first.y, last.x, last.y) then
            table.remove(tempNodes, #tempNodes)
        end
    end
    
    -- 2. Apply initial Noise Displacement masked by Growth Zone
    local totalPoints = #tempNodes
    local centerIdx = math.floor(totalPoints * (self.growthCenter / 100))
    local widthIdx = math.floor(totalPoints * (self.growthWidth / 100) * 0.5)
    
    for i, node in ipairs(tempNodes) do
        local distFromCenter = math.abs(i - centerIdx)
        
        local mask = 0
        if distFromCenter < widthIdx then
            local t = 1.0 - (distFromCenter / widthIdx)
            mask = t * t -- Quadratic
        end
        
        if mask > 0.001 then
            local n = self:noise(node.x * 0.05, node.y * 0.05)
            local ang = n * twopi
            -- Displace
            node.x = node.x + mcos(ang) * self.noiseAmplitude * mask
            node.y = node.y + msin(ang) * self.noiseAmplitude * mask
            node.newX = node.x
            node.newY = node.y
        end
        table.insert(self.nodes, node)
    end
    
    self.isInitialized = true
end

function simulate(self: DifferentialGrowth, dt: number)
    local count = #self.nodes
    if count < 2 then return end

    local targetLen = self.targetSegmentLength
    local sqRadius = self.repulsionRadius * self.repulsionRadius
    
    -- Parameters
    local kAttract = self.attractionStrength * 0.1
    local kRepel = self.repulsionStrength * 50.0
    local kGrowth = self.growthSpeed * 1.0
    
    -- Reset forces
    for i = 1, count do
        self.nodes[i].fx = 0
        self.nodes[i].fy = 0
    end
    
    local centerIdx = count * (self.growthCenter / 100)
    local widthEx = count * (self.growthWidth / 100) * 0.5
    local transitionZone = 10 -- indices buffer for smooth mask

    for i = 1, count do
        local ni = self.nodes[i]
        local distFromCenter = math.abs(i - centerIdx)
        local isActive = distFromCenter < (widthEx + transitionZone)

        -- A. Spring Forces (Integrity)
        -- For closed contours, wrap neighbors so endpoints stay connected.
        local prevIndex = i - 1
        local nextIndex = i + 1
        if self.isClosed then
            if prevIndex < 1 then prevIndex = count end
            if nextIndex > count then nextIndex = 1 end
        end

        if prevIndex >= 1 and prevIndex <= count then
            local prev = self.nodes[prevIndex]
            local dx = prev.x - ni.x
            local dy = prev.y - ni.y
            local d = length(dx, dy)
            local force = (d - targetLen) * kAttract
            local nx, ny = normalize(dx, dy)
            ni.fx = ni.fx + nx * force
            ni.fy = ni.fy + ny * force
        end
        
        if nextIndex >= 1 and nextIndex <= count then
            local next = self.nodes[nextIndex]
            local dx = next.x - ni.x
            local dy = next.y - ni.y
            local d = length(dx, dy)
            local force = (d - targetLen) * kAttract
            local nx, ny = normalize(dx, dy)
            ni.fx = ni.fx + nx * force
            ni.fy = ni.fy + ny * force
        end
        
        -- B. Repulsion (Volume)
        if isActive then
            for j = 1, count do
                if i ~= j then
                    local nj = self.nodes[j]
                    local dist2 = distSq(ni.x, ni.y, nj.x, nj.y)
                    if dist2 < sqRadius and dist2 > 0.001 then
                         local dist = math.sqrt(dist2)
                         local overlap = self.repulsionRadius - dist
                         local dx = ni.x - nj.x
                         local dy = ni.y - nj.y
                         local nx, ny = normalize(dx, dy)
                         
                         local repelForce = kRepel * overlap
                         ni.fx = ni.fx + nx * repelForce
                         ni.fy = ni.fy + ny * repelForce
                    end
                end
            end
        end
        
         -- C. Growth Force (Expansion)
         if distFromCenter < widthEx then
             local mask = 1.0 - (distFromCenter / widthEx)
             mask = mask * mask -- Quadratic
             
             -- Approximate normal based on neighbors (wrapped for closed paths)
             local prev = self.nodes[prevIndex >= 1 and prevIndex <= count and prevIndex or math.max(1, i-1)]
             local next = self.nodes[nextIndex >= 1 and nextIndex <= count and nextIndex or math.min(count, i+1)]
             local dx = next.x - prev.x
             local dy = next.y - prev.y
             local nx, ny = normalize(-dy, dx)
             
             ni.fx = ni.fx + nx * kGrowth * mask
             ni.fy = ni.fy + ny * kGrowth * mask
         end
    end
    
    -- Integration - Only Apply to Active Zone
    for i = 1, count do
        local distFromCenter = math.abs(i - centerIdx)
        
        local mask = 0
        if distFromCenter < widthEx then
            mask = 1
        elseif distFromCenter < (widthEx + transitionZone) then
            mask = 1.0 - (distFromCenter - widthEx) / transitionZone
        end

        if mask > 0 then
            local n = self.nodes[i]
            n.x = n.x + n.fx * dt * mask
            n.y = n.y + n.fy * dt * mask
        end
    end
    
    -- 2. Resampling (Adaptive Subdivision)
    local i = 1
    while i < #self.nodes do
        local n1 = self.nodes[i]
        local n2 = self.nodes[i+1]
        local d = length(n2.x - n1.x, n2.y - n1.y)

        local currentCount = #self.nodes
        local currentCenter = currentCount * (self.growthCenter / 100)
        local currentWidth = currentCount * (self.growthWidth / 100) * 0.5
        local distFromCenter = math.abs(i - currentCenter)
        local isGrowthZone = distFromCenter < currentWidth

        if isGrowthZone and d > targetLen then
            local midX = (n1.x + n2.x) * 0.5
            local midY = (n1.y + n2.y) * 0.5
            local point: Point = {x=midX, y=midY, fx=0, fy=0, newX=0, newY=0}
            table.insert(self.nodes, i + 1, point)
            i = i + 1 
        end
        i = i + 1
    end

    -- If closed, also resample the closing segment (last -> first)
    if self.isClosed and #self.nodes >= 3 then
        local n1 = self.nodes[#self.nodes]
        local n2 = self.nodes[1]
        local d = length(n2.x - n1.x, n2.y - n1.y)

        local currentCount = #self.nodes
        local currentCenter = currentCount * (self.growthCenter / 100)
        local currentWidth = currentCount * (self.growthWidth / 100) * 0.5
        local distFromCenter = math.abs(#self.nodes - currentCenter)
        local isGrowthZone = distFromCenter < currentWidth

        if isGrowthZone and d > targetLen then
            local midX = (n1.x + n2.x) * 0.5
            local midY = (n1.y + n2.y) * 0.5
            local point: Point = {x=midX, y=midY, fx=0, fy=0, newX=0, newY=0}
            table.insert(self.nodes, point)
        end
    end
    
    -- 3. Smoothing (Laplacian)
    for k = 1, #self.nodes do
        local distFromCenter = math.abs(k - centerIdx)
        if distFromCenter < (widthEx + transitionZone) then
            if self.isClosed then
                local prev = self.nodes[k == 1 and #self.nodes or (k-1)]
                local curr = self.nodes[k]
                local next = self.nodes[k == #self.nodes and 1 or (k+1)]
                curr.x = curr.x * 0.9 + (prev.x + next.x) * 0.05
                curr.y = curr.y * 0.9 + (prev.y + next.y) * 0.05
            else
                if k > 1 and k < #self.nodes then
                    local prev = self.nodes[k-1]
                    local curr = self.nodes[k]
                    local next = self.nodes[k+1]
                    curr.x = curr.x * 0.9 + (prev.x + next.x) * 0.05
                    curr.y = curr.y * 0.9 + (prev.y + next.y) * 0.05
                end
            end
        end
    end
end

function update(self: DifferentialGrowth, path: PathData): PathData
  -- Reset if time loops or first run
  if not self.isInitialized or self.time < 0.1 then
     self:initFromPath(path)
  end

  local outPath = Path.new()
  
  if #self.nodes > 0 then
      outPath:moveTo(Vector.xy(self.nodes[1].x, self.nodes[1].y))
      for i = 2, #self.nodes do
          local p = self.nodes[i]
          outPath:lineTo(Vector.xy(p.x, p.y))
      end

      -- Ensure closed contours stay closed
      if self.isClosed then
          outPath:close()
      end
  end

  return outPath
end

function init(self: DifferentialGrowth, context: Context)
  self.time = 0
  self.frameCount = 0
  self.isInitialized = false
  self.isClosed = false
  self.nodes = {}
  self.context = context
  return true
end

function advance(self: DifferentialGrowth, dt: number)
  self.frameCount = self.frameCount + 1
  local step = math.max(1, math.floor(self.processEveryNFrames))
  
  -- Skip frames to slow down growth
  if self.frameCount % step == 0 then
      self.time = self.time + dt
      
      if self.time < self.duration then
          self:simulate(dt)
      end
  end
  
  self.context:markNeedsUpdate()
  return true
end

return function(): PathEffect<DifferentialGrowth>
  return {
    growthCenter = 50,
    growthWidth = 40,
    duration = 10,
    processEveryNFrames = 5,
    targetSegmentLength = 5,
    repulsionRadius = 15,
    repulsionStrength = 0.05, 
    attractionStrength = 1.0, 
    growthSpeed = 1.0,
    noiseAmplitude = 2.0,
    
    time = 0,
    frameCount = 0,
    nodes = {},
    isInitialized = false,
    isClosed = false,
    context = late(),
    
    noise = noise,
    initFromPath = initFromPath,
    simulate = simulate,
    init = init,
    update = update,
    advance = advance,
  }
end