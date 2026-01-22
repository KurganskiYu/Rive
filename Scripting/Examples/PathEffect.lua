type BoilEffect = {
  -- Inputs for customization
  amplitude: Input<number>,
  frequency: Input<number>,
  speed: Input<number>,
  octaves: Input<number>,
  seed: Input<number>,
  roughness: Input<number>,

  -- Internal state
  time: number,
  context: Context,

  -- Methods
  noise: (self: BoilEffect, x: number, y: number, z: number) -> number,
  calculateOffset: (self: BoilEffect, x: number, y: number) -> (number, number),
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

-- Multi-octave noise for more detail
function calculateOffset(
  self: BoilEffect,
  x: number,
  y: number
): (number, number)
  local offsetX = 0
  local offsetY = 0
  local amplitude = self.amplitude
  local frequency = self.frequency * 0.01

  -- Add seed offset to create variation
  local seedOffset = self.seed * 1000

  -- Multiple octaves for detail
  for i = 0, math.floor(self.octaves) - 1 do
    local scale = 2 ^ i
    local weight = 1 / scale

    -- X offset using noise
    local noiseX = self:noise(
      (x + seedOffset) * frequency * scale,
      y * frequency * scale,
      self.time * self.speed + i * 10
    )
    -- Center noise around 0 before applying amplitude
    offsetX = offsetX + (noiseX - 0.5) * 2 * amplitude * weight

    -- Y offset using different noise sample
    local noiseY = self:noise(
      x * frequency * scale,
      (y + seedOffset + 100) * frequency * scale,
      self.time * self.speed + i * 10 + 50
    )
    -- Center noise around 0 before applying amplitude
    offsetY = offsetY + (noiseY - 0.5) * 2 * amplitude * weight
  end

  return offsetX, offsetY
end

function init(self: BoilEffect, context: Context): boolean
  self.time = 0
  self.context = context
  return true
end

-- Helper function to add roughness by subdividing segments
local function subdivideSegment(
  self: BoilEffect,
  outputPath: Path,
  startPoint: Vector,
  endPoint: Vector,
  divisions: number
)
  if divisions <= 1 then
    local offsetX, offsetY = self:calculateOffset(endPoint.x, endPoint.y)
    outputPath:lineTo(Vector.xy(endPoint.x + offsetX, endPoint.y + offsetY))
    return
  end

  for i = 1, divisions do
    local t = i / divisions
    local x = startPoint.x + (endPoint.x - startPoint.x) * t
    local y = startPoint.y + (endPoint.y - startPoint.y) * t
    local offsetX, offsetY = self:calculateOffset(x, y)
    outputPath:lineTo(Vector.xy(x + offsetX, y + offsetY))
  end
end

function update(self: BoilEffect, path: PathData): PathData
  local outputPath = Path.new()
  local lastPoint: Vector? = nil
  local roughnessDivisions = math.max(1, math.floor(self.roughness))

  -- Iterate through all commands in the input path
  for i = 1, #path do
    local cmd = path[i]

    if cmd.type == 'moveTo' then
      local point: Vector = cmd[1]
      local offsetX, offsetY = self:calculateOffset(point.x, point.y)
      local newPoint = Vector.xy(point.x + offsetX, point.y + offsetY)
      outputPath:moveTo(newPoint)
      lastPoint = newPoint
    elseif cmd.type == 'lineTo' then
      local point: Vector = cmd[1]
      if lastPoint and roughnessDivisions > 1 then
        subdivideSegment(self, outputPath, lastPoint, point, roughnessDivisions)
        local offsetX, offsetY = self:calculateOffset(point.x, point.y)
        lastPoint = Vector.xy(point.x + offsetX, point.y + offsetY)
      else
        local offsetX, offsetY = self:calculateOffset(point.x, point.y)
        local newPoint = Vector.xy(point.x + offsetX, point.y + offsetY)
        outputPath:lineTo(newPoint)
        lastPoint = newPoint
      end
    elseif cmd.type == 'cubicTo' then
      local cp1: Vector = cmd[1]
      local cp2: Vector = cmd[2]
      local endPoint: Vector = cmd[3]

      if roughnessDivisions > 1 then
        -- Subdivide cubic curve by sampling points along it
        local startPoint = lastPoint or Vector.xy(0, 0)
        for j = 1, roughnessDivisions do
          local t = j / roughnessDivisions
          local t2 = t * t
          local t3 = t2 * t
          local mt = 1 - t
          local mt2 = mt * mt
          local mt3 = mt2 * mt

          -- Cubic Bezier formula
          local x = mt3 * startPoint.x
            + 3 * mt2 * t * cp1.x
            + 3 * mt * t2 * cp2.x
            + t3 * endPoint.x
          local y = mt3 * startPoint.y
            + 3 * mt2 * t * cp1.y
            + 3 * mt * t2 * cp2.y
            + t3 * endPoint.y

          local offsetX, offsetY = self:calculateOffset(x, y)
          outputPath:lineTo(Vector.xy(x + offsetX, y + offsetY))
        end
        local offsetX, offsetY = self:calculateOffset(endPoint.x, endPoint.y)
        lastPoint = Vector.xy(endPoint.x + offsetX, endPoint.y + offsetY)
      else
        local offset1X, offset1Y = self:calculateOffset(cp1.x, cp1.y)
        local offset2X, offset2Y = self:calculateOffset(cp2.x, cp2.y)
        local offset3X, offset3Y = self:calculateOffset(endPoint.x, endPoint.y)

        outputPath:cubicTo(
          Vector.xy(cp1.x + offset1X, cp1.y + offset1Y),
          Vector.xy(cp2.x + offset2X, cp2.y + offset2Y),
          Vector.xy(endPoint.x + offset3X, endPoint.y + offset3Y)
        )
        lastPoint = Vector.xy(endPoint.x + offset3X, endPoint.y + offset3Y)
      end
    elseif cmd.type == 'quadTo' then
      local cp: Vector = cmd[1]
      local endPoint: Vector = cmd[2]

      if roughnessDivisions > 1 then
        -- Subdivide quadratic curve by sampling points along it
        local startPoint = lastPoint or Vector.xy(0, 0)
        for j = 1, roughnessDivisions do
          local t = j / roughnessDivisions
          local t2 = t * t
          local mt = 1 - t
          local mt2 = mt * mt

          -- Quadratic Bezier formula
          local x = mt2 * startPoint.x + 2 * mt * t * cp.x + t2 * endPoint.x
          local y = mt2 * startPoint.y + 2 * mt * t * cp.y + t2 * endPoint.y

          local offsetX, offsetY = self:calculateOffset(x, y)
          outputPath:lineTo(Vector.xy(x + offsetX, y + offsetY))
        end
        local offsetX, offsetY = self:calculateOffset(endPoint.x, endPoint.y)
        lastPoint = Vector.xy(endPoint.x + offsetX, endPoint.y + offsetY)
      else
        local offset1X, offset1Y = self:calculateOffset(cp.x, cp.y)
        local offset2X, offset2Y = self:calculateOffset(endPoint.x, endPoint.y)

        outputPath:quadTo(
          Vector.xy(cp.x + offset1X, cp.y + offset1Y),
          Vector.xy(endPoint.x + offset2X, endPoint.y + offset2Y)
        )
        lastPoint = Vector.xy(endPoint.x + offset2X, endPoint.y + offset2Y)
      end
    elseif cmd.type == 'close' then
      outputPath:close()
      lastPoint = nil
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
    frequency = 1,
    speed = 2,
    octaves = 3,
    seed = 0,
    roughness = 3,
    time = 0,
    noise = noise,
    calculateOffset = calculateOffset,
    init = init,
    update = update,
    advance = advance,
    context = late(),
  }
end
