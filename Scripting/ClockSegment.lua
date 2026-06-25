-- Procedural Clock Segment Path Effect
-- Generates a wedge or donut/ring segment of a circular face based on start and end hours.

type ClockSegment = {
  radius: Input<number>,
  timeStart: Input<number>,
  timeEnd: Input<number>,
  innerRadius: Input<number>,
  precision: Input<number>,

  _outPath: Path,
  _context: Context?,

  -- Local caches for performance optimization to minimize resource usage
  _lastRadius: number,
  _lastTimeStart: number,
  _lastTimeEnd: number,
  _lastInnerRadius: number,
  _lastPrecision: number,
}

local function init(self: ClockSegment, context: Context): boolean
  self._context = context
  self._outPath = Path.new()
  return true
end

local function advance(self: ClockSegment, seconds: number): boolean
  if self._context then
    self._context:markNeedsUpdate()
  end
  return true
end

local function update(self: ClockSegment, inPath: PathData): PathData
  local r = self.radius or 100
  local tStart = self.timeStart or 12
  local tEnd = self.timeEnd or 3
  local ri = self.innerRadius or 0
  local prec = self.precision or 4

  -- Performance Guard: Only recalculate and rebuild the path if inputs changed
  if r == self._lastRadius and
     tStart == self._lastTimeStart and
     tEnd == self._lastTimeEnd and
     ri == self._lastInnerRadius and
     prec == self._lastPrecision then
    return self._outPath
  end

  -- Update cache
  self._lastRadius = r
  self._lastTimeStart = tStart
  self._lastTimeEnd = tEnd
  self._lastInnerRadius = ri
  self._lastPrecision = prec

  local outPath = self._outPath
  outPath:reset()

  -- Bounds clamping
  r = math.max(0, r)
  ri = math.max(0, math.min(ri, r - 0.01))
  prec = math.max(1, prec)

  -- Angle Mapping to Clock Hours:
  -- 12 o'clock is at the top (-pi/2)
  -- 3 o'clock is at the right (0)
  -- 6 o'clock is at the bottom (pi/2)
  -- 9 o'clock is at the left (pi)
  local angleStart = (tStart * math.pi / 6) - (math.pi / 2)
  local angleEnd = (tEnd * math.pi / 6) - (math.pi / 2)

  -- Ensure we sweep clockwise (increasing angle) from angleStart to angleEnd
  if angleEnd < angleStart then
    angleEnd = angleEnd + (2 * math.pi)
  elseif angleEnd == angleStart then
    -- Return an empty path if hours are completely identical
    return outPath
  end

  local sweepAngle = angleEnd - angleStart
  local sweepHours = sweepAngle * 6 / math.pi
  local steps = math.ceil(sweepHours * prec)
  
  -- Safety clamping to ensure smoothness without exceeding resource thresholds
  if steps < 4 then
    steps = 4
  elseif steps > 180 then
    steps = 180
  end

  local function getPoint(angle: number, rad: number): Vector
    return Vector.xy(rad * math.cos(angle), rad * math.sin(angle))
  end

  -- Construction of procedural geography
  if ri <= 0 then
    -- Wedge / Pie slice
    outPath:moveTo(Vector.xy(0, 0))
    outPath:lineTo(getPoint(angleStart, r))
    
    for i = 1, steps do
      local t = i / steps
      local angle = angleStart + t * sweepAngle
      outPath:lineTo(getPoint(angle, r))
    end
    
    outPath:close()
  else
    -- Ring / Donut segment
    outPath:moveTo(getPoint(angleStart, r))
    
    -- Outer arc (clockwise)
    for i = 1, steps do
      local t = i / steps
      local angle = angleStart + t * sweepAngle
      outPath:lineTo(getPoint(angle, r))
    end
    
    -- Connector line to inner arc
    outPath:lineTo(getPoint(angleEnd, ri))
    
    -- Inner arc (counter-clockwise back to start angle)
    for i = 1, steps do
      local t = i / steps
      local angle = angleEnd - t * sweepAngle
      outPath:lineTo(getPoint(angle, ri))
    end
    
    outPath:close()
  end

  return outPath
end

return function(): PathEffect<ClockSegment>
  return {
    radius = 100,
    timeStart = 12,
    timeEnd = 3,
    innerRadius = 0,
    precision = 4,

    _outPath = Path.new(),
    _context = nil,

    _lastRadius = -1,
    _lastTimeStart = -1,
    _lastTimeEnd = -1,
    _lastInnerRadius = -1,
    _lastPrecision = -1,

    init = init,
    advance = advance,
    update = update,
  }
end

