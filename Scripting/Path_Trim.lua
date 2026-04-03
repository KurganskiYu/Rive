type PathTrim = {
  percentStart: Input<number>,
  percentEnd: Input<number>,
  slide: Input<number>,
  _outPath: Path,
  _context: Context?,
}

local function init(self: PathTrim, ctx: Context): boolean
  self._context = ctx
  self._outPath = Path.new()
  return true
end

local function advance(self: PathTrim, seconds: number): boolean
  if self._context then
    self._context:markNeedsUpdate()
  end
  return true
end

local function update(self: PathTrim, inPath: PathData): PathData
  local outPath = self._outPath
  outPath:reset()

  local measure = inPath:measure()
  local totalLength = measure.length
  if totalLength == 0 then
    return outPath
  end

  local pStart = self.percentStart or 0
  local pEnd = self.percentEnd or 100
  local pSlide = self.slide or 0

  local startDist = ((pStart + pSlide) / 100) * totalLength
  local endDist = ((pEnd + pSlide) / 100) * totalLength

  startDist = startDist % totalLength
  if startDist < 0 then startDist = startDist + totalLength end
  endDist = endDist % totalLength
  if endDist < 0 then endDist = endDist + totalLength end

  local diff = math.abs((self.percentEnd or 100) - (self.percentStart or 0))

  if diff >= 100 then
    measure:extract(0, totalLength, outPath, true)
  elseif endDist < startDist then
    measure:extract(startDist, totalLength, outPath, true)
    measure:extract(0, endDist, outPath, true)
  else
    measure:extract(startDist, endDist, outPath, true)
  end

  return outPath
end

return function(): PathEffect<PathTrim>
  return {
    percentStart = late(),
    percentEnd = late(),
    slide = late(),
    _outPath = Path.new(),
    _context = nil,
    init = init,
    advance = advance,
    update = update,
  }
end
