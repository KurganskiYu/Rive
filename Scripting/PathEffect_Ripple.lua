type BoilEffect = {
  -- Inputs for customization
  amplitude: Input<number>,
  frequency: Input<number>,
  speed: Input<number>,
  octaves: Input<number>,
  seed: Input<number>,
  roughness: Input<number>,
  subdivision: Input<number>,

  -- Internal state
  time: number,
  context: Context,

  -- Methods
  noise: (self: BoilEffect, x: number, y: number, z: number) -> number,
  calculateOffset: (self: BoilEffect, distance: number) -> number,
}

-- Simple pseudo-random function using sine-based hashing
local function hash(x: number, y: number, z: number): number
  local n = x * 374761393 + y * 668265263 + z * 1274126177
  -- Use fractional part of sine for pseudo-random values
  local value = math.sin(n) * 43758.5453123
  return value - math.floor(value)
end

-- 3D Perlin-style noise approximation
function noise(self: BoilEffect, x: number, y: number, z: number): number
  local xi = math.floor(x)
  local yi = math.floor(y)
  local zi = math.floor(z)

  local xf = x - xi
  local yf = y - yi
  local zf = z - zi

  -- Smoothstep interpolation
  local u = xf * xf * (3.0 - 2.0 * xf)
  local v = yf * yf * (3.0 - 2.0 * yf)
  local w = zf * zf * (3.0 - 2.0 * zf)

  -- Sample 8 corners of the cube
  local c000 = hash(xi, yi, zi)
  local c100 = hash(xi + 1, yi, zi)
  local c010 = hash(xi, yi + 1, zi)
  local c110 = hash(xi + 1, yi + 1, zi)
  local c001 = hash(xi, yi, zi + 1)
  local c101 = hash(xi + 1, yi, zi + 1)
  local c011 = hash(xi, yi + 1, zi + 1)
  local c111 = hash(xi + 1, yi + 1, zi + 1)

  -- Trilinear interpolation
  local x00 = c000 * (1 - u) + c100 * u
  local x10 = c010 * (1 - u) + c110 * u
  local x01 = c001 * (1 - u) + c101 * u
  local x11 = c011 * (1 - u) + c111 * u

  local y0 = x00 * (1 - v) + x10 * v
  local y1 = x01 * (1 - v) + x11 * v

  return y0 * (1 - w) + y1 * w
end

-- Wave offset based on distance along path (1D noise)
function calculateOffset(self: BoilEffect, distance: number): number
  local amplitude = self.amplitude
  local frequency = self.frequency * 0.01

  -- 1D noise based on distance and time
  -- We use y=0 and z=time for animation
  local n = self:noise(
    distance * frequency,
    0,
    self.time * self.speed
  )

  -- Map 0..1 to -1..1 then scale by amplitude
  return (n - 0.5) * 2 * amplitude
end

function init(self: BoilEffect, context: Context): boolean
  self.time = 0
  self.context = context
  return true
end

-- Math helpers
local function length(x: number, y: number): number
  return math.sqrt(x * x + y * y)
end

local function normalize(x: number, y: number): (number, number)
  local l = length(x, y)
  if l > 0.0001 then
    return x / l, y / l
  end
  return 0, 0
end

function update(self: BoilEffect, path: PathData): PathData
  local outputPath = Path.new()
  local lastX, lastY = 0, 0
  local currentDistance = 0
  
  -- Use subdivision as density (steps per ~10 units)
  local density = math.max(0.1, self.subdivision * 0.1)

  for i = 1, #path do
    local cmd = path[i]

    if cmd.type == 'moveTo' then
      local pt: Vector = cmd[1]
      outputPath:moveTo(pt)
      lastX, lastY = pt.x, pt.y
      currentDistance = 0
      
    elseif cmd.type == 'lineTo' then
      local pt: Vector = cmd[1]
      local dx = pt.x - lastX
      local dy = pt.y - lastY
      local len = length(dx, dy)
      
      local steps = math.ceil(len * density)
      if steps < 1 then steps = 1 end
      
      -- Normal vector (rotate tangent 90 degrees)
      local nx, ny = normalize(dx, dy)
      local perpX, perpY = -ny, nx
      
      for s = 1, steps do
        local t = s / steps
        local d = currentDistance + len * t
        local offset = self:calculateOffset(d)
        
        local x = lastX + dx * t + perpX * offset
        local y = lastY + dy * t + perpY * offset
        outputPath:lineTo(Vector.xy(x, y))
      end
      
      lastX, lastY = pt.x, pt.y
      currentDistance = currentDistance + len

    elseif cmd.type == 'cubicTo' then
      local cp1: Vector = cmd[1]
      local cp2: Vector = cmd[2]
      local endPoint: Vector = cmd[3]
      
      -- Approximate length using control polygon
      local l1 = length(cp1.x - lastX, cp1.y - lastY)
      local l2 = length(cp2.x - cp1.x, cp2.y - cp1.y)
      local l3 = length(endPoint.x - cp2.x, endPoint.y - cp2.y)
      local approxLen = l1 + l2 + l3
      
      local steps = math.ceil(approxLen * density)
      if steps < 1 then steps = 1 end
      
      local startX, startY = lastX, lastY
      
      for s = 1, steps do
        local t = s / steps
        local mt = 1 - t
        local mt2 = mt * mt
        local mt3 = mt2 * mt
        local t2 = t * t
        local t3 = t2 * t
        
        -- Position
        local x = mt3 * startX + 3 * mt2 * t * cp1.x + 3 * mt * t2 * cp2.x + t3 * endPoint.x
        local y = mt3 * startY + 3 * mt2 * t * cp1.y + 3 * mt * t2 * cp2.y + t3 * endPoint.y
        
        -- Derivative (Tangent)
        -- 3(1-t)^2(P1-P0) + 6(1-t)t(P2-P1) + 3t^2(P3-P2)
        local dx = 3 * mt2 * (cp1.x - startX) + 6 * mt * t * (cp2.x - cp1.x) + 3 * t2 * (endPoint.x - cp2.x)
        local dy = 3 * mt2 * (cp1.y - startY) + 6 * mt * t * (cp2.y - cp1.y) + 3 * t2 * (endPoint.y - cp2.y)
        
        local nx, ny = normalize(dx, dy)
        local perpX, perpY = -ny, nx
        
        local d = currentDistance + approxLen * t -- Approximation of arc length
        local offset = self:calculateOffset(d)
        
        outputPath:lineTo(Vector.xy(x + perpX * offset, y + perpY * offset))
      end
      
      lastX, lastY = endPoint.x, endPoint.y
      currentDistance = currentDistance + approxLen

    elseif cmd.type == 'quadTo' then
      local cp: Vector = cmd[1]
      local endPoint: Vector = cmd[2]
      
      local l1 = length(cp.x - lastX, cp.y - lastY)
      local l2 = length(endPoint.x - cp.x, endPoint.y - cp.y)
      local approxLen = l1 + l2
      
      local steps = math.ceil(approxLen * density)
      if steps < 1 then steps = 1 end
      
      local startX, startY = lastX, lastY
      
      for s = 1, steps do
        local t = s / steps
        local mt = 1 - t
        local mt2 = mt * mt
        local t2 = t * t
        
        -- Position: (1-t)^2 P0 + 2(1-t)t P1 + t^2 P2
        local x = mt2 * startX + 2 * mt * t * cp.x + t2 * endPoint.x
        local y = mt2 * startY + 2 * mt * t * cp.y + t2 * endPoint.y
        
        -- Derivative: 2(1-t)(P1-P0) + 2t(P2-P1)
        local dx = 2 * mt * (cp.x - startX) + 2 * t * (endPoint.x - cp.x)
        local dy = 2 * mt * (cp.y - startY) + 2 * t * (endPoint.y - cp.y)
        
        local nx, ny = normalize(dx, dy)
        local perpX, perpY = -ny, nx
        
        local d = currentDistance + approxLen * t
        local offset = self:calculateOffset(d)
        
        outputPath:lineTo(Vector.xy(x + perpX * offset, y + perpY * offset))
      end
      
      lastX, lastY = endPoint.x, endPoint.y
      currentDistance = currentDistance + approxLen
      
    elseif cmd.type == 'close' then
      outputPath:close()
    end
  end

  return outputPath
end

function advance(self: BoilEffect, seconds: number): boolean
  self.time = self.time + seconds
  self.context:markNeedsUpdate()
  return true
end

return function(): PathEffect<BoilEffect>
  return {
    amplitude = 12,
    frequency = 5,
    speed = 200,
    octaves = 1,
    seed = 0,
    roughness = 0,
    subdivision = 5,
    time = 0,
    noise = noise,
    calculateOffset = calculateOffset,
    init = init,
    update = update,
    advance = advance,
    context = late(),
  }
end
