-- Artboard Path Cloner Node Script

type PathCloner = {
  pathArtwork: Input<Artboard>,
  drawPath: Input<boolean>,

  cloneArtwork: Input<Artboard>,
  clones: Input<number>,
  percentage: Input<number>,
  slide: Input<number>,
  loop: Input<boolean>,
  invert: Input<boolean>,
  startScale: Input<number>,
  endScale: Input<number>,
  startRotation: Input<number>,
  endRotation: Input<number>,
  pathRotation: Input<number>,
  orientAlongCurve: Input<boolean>,

  _pathPaint: Paint,
  _pathInstance: Artboard?,
  _cloneInstance: Artboard?,
  _context: Context?,
}

local function init(self: PathCloner, ctx: Context): boolean
  self._context = ctx
  self._pathPaint = Paint.with({
    style = "stroke",
    color = 0xFF00FF00,
    thickness = 2,
  })
  return true
end

local function advance(self: PathCloner, seconds: number): boolean
  if self.pathArtwork and not self._pathInstance then
    self._pathInstance = self.pathArtwork:instance()
  end
  -- Advance the path artboard every frame so world transforms are computed
  if self._pathInstance then
    self._pathInstance:advance(seconds)
  end

  if self.cloneArtwork and not self._cloneInstance then
    self._cloneInstance = self.cloneArtwork:instance()
  end
  if self._cloneInstance then
    self._cloneInstance:advance(seconds)
  end

  if self._context then
    self._context:markNeedsUpdate()
  end
  return true
end

-- Walk a node and its children to find the first available PathData.
local function resolvePathData(node: NodeData): (PathData?, Mat2D?)
  local pd = (node :: any):asPath()
  if pd then return pd, (node :: any).worldTransform end
  for _, child in ipairs((node :: any).children) do
    local cpd = (child :: any):asPath()
    if cpd then return cpd, (child :: any).worldTransform end
  end
  return nil, nil
end

-- Recursively search a node tree for the first node that yields PathData.
local function findFirstPathData(node: NodeData): (PathData?, Mat2D?)
  local pd, xf = resolvePathData(node)
  if pd then return pd, xf end
  for _, child in ipairs((node :: any).children) do
    local cpd, cxf = findFirstPathData(child)
    if cpd then return cpd, cxf end
  end
  return nil, nil
end

local function draw(self: PathCloner, renderer: Renderer)
  if not self._pathInstance or not self._cloneInstance then return end

  -- Draw the path artboard off-screen so it computes world transforms for its nodes.
  -- We save/restore and immediately clip to nothing so it is invisible.
  local hiddenPath = Path.new()
  renderer:save()
  renderer:clipPath(hiddenPath)
  self._pathInstance:draw(renderer)
  renderer:restore()

  -- Find the first node in the artboard that contains path data.
  local rootNode = self._pathInstance:node("")
  if not rootNode then return end

  local pathData, xform = findFirstPathData(rootNode)
  if not pathData or not xform then return end

  -- Rebuild a local Path from the live PathData commands
  local dummyPath = Path.new()
  for i = 1, #pathData do
    local cmd = pathData[i]
    if cmd.type == "moveTo" then
      dummyPath:moveTo(cmd[1])
    elseif cmd.type == "lineTo" then
      dummyPath:lineTo(cmd[1])
    elseif cmd.type == "cubicTo" then
      dummyPath:cubicTo(cmd[1], cmd[2], cmd[3])
    elseif cmd.type == "close" then
      dummyPath:close()
    end
  end

  -- World transform of the Shape places the path correctly on canvas

  if self.drawPath then
    renderer:save()
    renderer:transform(xform)
    renderer:drawPath(dummyPath, self._pathPaint)
    renderer:restore()
  end

  if self.clones <= 0 then return end

  local measure = dummyPath:measure()
  local totalLength = measure.length
  if totalLength <= 0.001 then return end

  local filledPct = math.clamp(self.percentage, 0, 100)
  local filledLength = totalLength * (filledPct / 100.0)
  local n = math.max(1, math.floor(self.clones))

  for i = 0, n - 1 do
    local t = if n > 1 then i / (n - 1) else 0

    local dist = t * filledLength
    if self.invert then
      dist = filledLength - dist
    end

    dist = dist + totalLength * (self.slide / 100.0)
    if self.loop then
      dist = dist % totalLength
      if dist < 0 then dist = dist + totalLength end
    else
      dist = math.clamp(dist, 0, totalLength)
    end

    local pos, tan = measure:positionAndTangent(dist)

    local base_angle    = self.pathRotation * (math.pi / 180.0)
    local anim_angle    = (self.startRotation + t * (self.endRotation - self.startRotation)) * (math.pi / 180.0)
    local tangent_angle = if self.orientAlongCurve then math.atan2(tan.y, tan.x) else 0

    local final_angle   = base_angle + anim_angle + tangent_angle
    local current_scale = self.startScale + t * (self.endScale - self.startScale)

    local cloneMat =
      xform
      * Mat2D.withTranslation(pos.x, pos.y)
      * Mat2D.withRotation(final_angle)
      * Mat2D.withScale(current_scale, current_scale)

    renderer:save()
    renderer:transform(cloneMat)
    self._cloneInstance:draw(renderer)
    renderer:restore()
  end
end

return function(): Node<PathCloner>
  return {
    pathArtwork = late(),
    drawPath = true,

    cloneArtwork = late(),
    clones = 5,
    percentage = 100,
    slide = 0,
    loop = true,
    invert = false,
    startScale = 1.0,
    endScale = 1.0,
    startRotation = 0,
    endRotation = 0,
    pathRotation = 0,
    orientAlongCurve = true,
    _pathPaint = Paint.new(),
    _pathInstance = nil,
    _cloneInstance = nil,
    _context = nil,

    init = init,
    advance = advance,
    draw = draw,
  }
end
