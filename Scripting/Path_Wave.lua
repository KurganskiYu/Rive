-- Ripple / Line Wave Modifier
-- Subdivides the path and applies a noise-based offset along the normal of each point.

type RippleEffect = {
  amplitude: Input<number>,
  frequency: Input<number>,
  speed: Input<number>,
  noiseSpeed: Input<number>,
  subdivision: Input<number>,
  octaves: Input<number>,
  startFade: Input<number>,
  endFade: Input<number>,
  useWorldSpace: Input<boolean>,
  rotation: Input<number>,
  time: number,
  totalLength: number,
  context: Context,
  -- Methods
  noise: (self: RippleEffect, x: number, y: number) -> number,
  getOffset: (self: RippleEffect, distance: number, pathLength: number, x: number, y: number) -> number,
}

local function length(x: number, y: number): number
  return math.sqrt(x * x + y * y)
end

local function normalize(x: number, y: number): (number, number)
  local l = length(x, y)
  if l > 0.0001 then return x / l, y / l end
  return 0, 0
end

-- Optimization: Cache math functions for performance
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
    
    -- Quintic interpolation
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

local function fbm(x: number, y: number, rough: number, octaves: number): number
    local total = 0
    local amplitude = 1
    local maxValue = 0
    local freq = 0.5 

    for i = 1, octaves do
        total = total + perlin2D(x * freq, y * freq) * amplitude
        maxValue = maxValue + amplitude
        amplitude = amplitude * rough
        freq = freq * 2
    end

    return (total / maxValue) * 1.5
end

-- Simple deterministic 2D noise
function noise(self: RippleEffect, x: number, y: number): number
  if self.octaves == 0 then
    return msin(x)
  end
  return fbm(x, y, 0.5, self.octaves)
end

function getOffset(self: RippleEffect, distance: number, pathLength: number, x: number, y: number): number
  local n = 0
  if self.useWorldSpace then
    local rad = self.rotation * 0.0174533
    local c = mcos(rad)
    local s = msin(rad)
    
    local rx = x * c - y * s
    local ry = x * s + y * c

    local freq = self.frequency * 0.01
    local sx = rx * freq - (self.time * self.speed)
    local sy = ry * freq - (self.time * self.noiseSpeed)
    n = self:noise(sx, sy)
  else
    -- The ripples expand from start to end; we shift phase by distance
    local phase = distance * self.frequency * 0.01 - (self.time * self.speed)
    local ny = self.time * self.noiseSpeed
    n = self:noise(phase, ny)
  end

  local fade = 1.0
  -- Start fade
  if self.startFade > 0 and pathLength > 0 then
    local startFadeLen = pathLength * (self.startFade / 100)
    if distance < startFadeLen then
      local t = distance / startFadeLen
      fade = fade * (t * t) -- Quadratic
    end
  end
  -- End fade
  if self.endFade > 0 and pathLength > 0 then
    local endFadeLen = pathLength * (self.endFade / 100)
    if distance > (pathLength - endFadeLen) then
      local t = (pathLength - distance) / endFadeLen
      fade = fade * (t * t) -- Quadratic
    end
  end

  return n * self.amplitude * fade
end

function update(self: RippleEffect, path: PathData): PathData
  local outPath = Path.new()
  local lastX, lastY = 0, 0
  local dist = 0
  
  -- Calculate total path length first for fading
  local totalLen = 0
  local px, py = 0, 0
  local moveX, moveY = 0, 0
  for i = 1, #path do
    local cmd = path[i]
    if cmd.type == 'moveTo' then
        px, py = cmd[1].x, cmd[1].y
        moveX, moveY = px, py
    elseif cmd.type == 'lineTo' then
        local pt = cmd[1]
        totalLen = totalLen + length(pt.x - px, pt.y - py)
        px, py = pt.x, pt.y
    elseif cmd.type == 'cubicTo' then
        -- Approx cubic
        local cp1, cp2, ep = cmd[1], cmd[2], cmd[3]
        totalLen = totalLen + length(cp1.x - px, cp1.y - py) + length(cp2.x - cp1.x, cp2.y - cp1.y) + length(ep.x - cp2.x, ep.y - cp2.y)
        px, py = ep.x, ep.y
    elseif cmd.type == 'quadTo' then
        -- Approx quad
        local cp, ep = cmd[1], cmd[2]
        totalLen = totalLen + length(cp.x - px, cp.y - py) + length(ep.x - cp.x, ep.y - cp.y)
        px, py = ep.x, ep.y
    elseif cmd.type == 'close' then
         -- Close if needed
    end
  end
  self.totalLength = totalLen

  -- Avoid too low density
  local density = math.max(0.05, self.subdivision * 0.05)

  for i = 1, #path do
    local cmd = path[i]

    if cmd.type == 'moveTo' then
      local pt = cmd[1]
      outPath:moveTo(pt)
      lastX, lastY = pt.x, pt.y
      dist = 0

    elseif cmd.type == 'lineTo' then
      local pt = cmd[1]
      local dx = pt.x - lastX
      local dy = pt.y - lastY
      local len = length(dx, dy)
      
      -- Calculate number of segments for this line
      local steps = math.ceil(len * density)
      if steps < 1 then steps = 1 end
      
      local nx, ny = normalize(dx, dy)
      local px, py = -ny, nx -- Perpendicular vector
      
      -- Skip the last point of intermediate segments to smooth creases
      local limit = steps
      if i < #path then
        limit = steps - 1
      end

      for s = 1, limit do
        local t = s / steps
        local currentLen = len * t
        
        local bx = lastX + dx * t
        local by = lastY + dy * t
        local offset = self:getOffset(dist + currentLen, self.totalLength, bx, by)
        
        local x = bx + px * offset
        local y = by + py * offset
        outPath:lineTo(Vector.xy(x, y))
      end
      
      lastX, lastY = pt.x, pt.y
      dist = dist + len

    elseif cmd.type == 'cubicTo' then
      local cp1, cp2, ep = cmd[1], cmd[2], cmd[3]
      -- Approximate cubic length
      local l1 = length(cp1.x - lastX, cp1.y - lastY)
      local l2 = length(cp2.x - cp1.x, cp2.y - cp1.y)
      local l3 = length(ep.x - cp2.x, ep.y - cp2.y)
      local approxLen = l1 + l2 + l3
      
      local steps = math.ceil(approxLen * density)
      if steps < 1 then steps = 1 end
      
      local startX, startY = lastX, lastY
      
      local limit = steps
      if i < #path then
        limit = steps - 1
      end
       
      for s = 1, limit do
        local t = s / steps
        local mt = 1 - t
        local mt2 = mt * mt
        local mt3 = mt2 * mt
        local t2 = t * t
        local t3 = t2 * t
        
        -- Point on curve
        local x = mt3*startX + 3*mt2*t*cp1.x + 3*mt*t2*cp2.x + t3*ep.x
        local y = mt3*startY + 3*mt2*t*cp1.y + 3*mt*t2*cp2.y + t3*ep.y
        
        -- Derivative for normal
        local dx = 3*mt2*(cp1.x - startX) + 6*mt*t*(cp2.x - cp1.x) + 3*t2*(ep.x - cp2.x)
        local dy = 3*mt2*(cp1.y - startY) + 6*mt*t*(cp2.y - cp1.y) + 3*t2*(ep.y - cp2.y)
        
        local nx, ny = normalize(dx, dy)
        local px, py = -ny, nx
        
        local offset = self:getOffset(dist + approxLen * t, self.totalLength, x, y)
        outPath:lineTo(Vector.xy(x + px * offset, y + py * offset))
      end

      lastX, lastY = ep.x, ep.y
      dist = dist + approxLen

    elseif cmd.type == 'quadTo' then
       local cp, ep = cmd[1], cmd[2]
       local l1 = length(cp.x - lastX, cp.y - lastY)
       local l2 = length(ep.x - cp.x, ep.y - cp.y)
       local approxLen = l1 + l2

       local steps = math.ceil(approxLen * density)
       if steps < 1 then steps = 1 end
       
       local startX, startY = lastX, lastY

       local limit = steps
       if i < #path then
         limit = steps - 1
       end

       for s = 1, limit do
         local t = s / steps
         local mt = 1 - t
         -- Point
         local x = mt*mt*startX + 2*mt*t*cp.x + t*t*ep.x
         local y = mt*mt*startY + 2*mt*t*cp.y + t*t*ep.y
         -- Derivative
         local dx = 2*mt*(cp.x - startX) + 2*t*(ep.x - cp.x)
         local dy = 2*mt*(cp.y - startY) + 2*t*(ep.y - cp.y)
         
         local nx, ny = normalize(dx, dy)
         local px, py = -ny, nx
         
         local offset = self:getOffset(dist + approxLen * t, self.totalLength, x, y)
         outPath:lineTo(Vector.xy(x + px * offset, y + py * offset))
       end

       lastX, lastY = ep.x, ep.y
       dist = dist + approxLen

    elseif cmd.type == 'close' then
      outPath:close()
    end
  end

  return outPath
end

function init(self: RippleEffect, context: Context)
  self.time = 0
  self.context = context
  return true
end

function advance(self: RippleEffect, dt: number)
  self.time = self.time + dt
  self.context:markNeedsUpdate()
  return true
end

return function(): PathEffect<RippleEffect>
  return {
    amplitude = 15,
    frequency = 10,
    speed = 5,
    noiseSpeed = 1,
    subdivision = 10,
    octaves = 1,
    startFade = 5,
    endFade = 5,
    useWorldSpace = false,
    rotation = 0,
    time = 0,
    totalLength = 0,
    context = late(),
    noise = noise,
    getOffset = getOffset,
    init = init,
    update = update,
    advance = advance,
  }
end