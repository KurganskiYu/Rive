-- Artboard Path Cloner Node Script

type PathCloner = {
  usePathMode: Input<boolean>,

  pathArtwork: Input<Artboard>,
  pathNodeName: Input<string>,
  drawPath: Input<boolean>,

  cloneArtwork: Input<Artboard>,
  clones: Input<number>,
  percentStart: Input<number>,
  percentEnd: Input<number>,
  slide: Input<number>,
  loop: Input<boolean>,
  invert: Input<boolean>,
  
  countX: Input<number>,
  countY: Input<number>,
  spiralMode: Input<boolean>,
  offsetX: Input<number>,
  offsetY: Input<number>,
  rotationStep: Input<number>,
  centerX: Input<number>,
  centerY: Input<number>,

  baseScale: Input<number>,
  scaleStepX: Input<number>,
  scaleStepY: Input<number>,

  baseRotation: Input<number>,
  rotationStepX: Input<number>,
  rotationStepY: Input<number>,

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
  if not self._cloneInstance then return end

  if self.usePathMode then
    if not self._pathInstance then return end

    -- Draw the path artboard off-screen so it computes world transforms for its nodes.
    -- We save/restore and immediately clip to nothing so it is invisible.
    local hiddenPath = Path.new()
    renderer:save()
    renderer:clipPath(hiddenPath)
    self._pathInstance:draw(renderer)
    renderer:restore()

    -- Find the first node in the artboard that contains path data.
    local targetName = self.pathNodeName or ""
    local rootNode = self._pathInstance:node(targetName)
    
    -- Fallbacks for common default names if custom name fails or isn't provided
    if not rootNode then
      rootNode = self._pathInstance:node("Root") or self._pathInstance:node("")
    end
    
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

    local pClones = self.clones or 5
    if pClones <= 0 then return end

    local measure = dummyPath:measure()
    local totalLength = measure.length
    if totalLength <= 0.001 then return end

    local pPercentStart = self.percentStart or 0
    local pPercentEnd = self.percentEnd or 100
    
    local startPct = math.clamp(pPercentStart, 0, 100)
    local endPct = math.clamp(pPercentEnd, 0, 100)
    local tStart = startPct / 100.0
    local tEnd = endPct / 100.0
    
    local pSlide = self.slide or 0
    local n = math.max(1, math.floor(pClones))

    for i = 0, n - 1 do
      local t = if n > 1 then i / (n - 1) else 0

      if self.invert then
        t = 1.0 - t
      end
      
      -- Map normalized t (0-1) to the restricted range between startPct and endPct
      local mapped_t = tStart + t * (tEnd - tStart)
      
      local dist = mapped_t * totalLength
      dist = dist + totalLength * (pSlide / 100.0)
      if self.loop then
        dist = dist % totalLength
        if dist < 0 then dist = dist + totalLength end
      else
        dist = math.clamp(dist, 0, totalLength)
      end

      local pos, tan = measure:positionAndTangent(dist)

      local pBaseScale = self.baseScale or 1.0
      local pScaleStepX = self.scaleStepX or 0
      local pBaseRotation = self.baseRotation or 0
      local pRotationStepX = self.rotationStepX or 0
      local pPathRotation = self.pathRotation or 0

      local base_angle    = pPathRotation * (math.pi / 180.0)
      local anim_angle    = (pBaseRotation + i * pRotationStepX) * (math.pi / 180.0)
      local tangent_angle = if self.orientAlongCurve then math.atan2(tan.y, tan.x) else 0

      local final_angle   = base_angle + anim_angle + tangent_angle
      local current_scale = pBaseScale + i * pScaleStepX

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
  else
    local cCountX = self.countX or 1
    local cCountY = self.countY or 1
    local nx = math.max(1, math.floor(cCountX))
    local ny = math.max(1, math.floor(cCountY))
    
    local totalClones = nx * ny
    if totalClones <= 0 then return end
    
    local rotRad = (self.rotationStep or 0) * (math.pi / 180.0)
    local baseRad = (self.baseRotation or 0) * (math.pi / 180.0)
    local rotStepXRad = (self.rotationStepX or 0) * (math.pi / 180.0)
    local rotStepYRad = (self.rotationStepY or 0) * (math.pi / 180.0)
    local cX = self.centerX or 0
    local cY = self.centerY or 0
    local offX = self.offsetX or 0
    local offY = self.offsetY or 0
    local bScale = self.baseScale or 1.0
    local sStepX = self.scaleStepX or 0
    local sStepY = self.scaleStepY or 0
    
    for ix = 0, nx - 1 do
      for iy = 0, ny - 1 do
        local index = ix * ny + iy
        
        local px = ix * offX
        local py = iy * offY
        
        local step_angle = if self.spiralMode then index * rotRad else ix * rotRad
        
        local dx = px - cX
        local dy = py - cY
        
        local rotX = cX + dx * math.cos(step_angle) - dy * math.sin(step_angle)
        local rotY = cY + dx * math.sin(step_angle) + dy * math.cos(step_angle)
        
        local current_scale = bScale + ix * sStepX + iy * sStepY
        local clone_angle = baseRad + (ix * rotStepXRad) + (iy * rotStepYRad) + step_angle

        local cloneMat = Mat2D.withTranslation(rotX, rotY)
          * Mat2D.withRotation(clone_angle)
          * Mat2D.withScale(current_scale, current_scale)

        renderer:save()
        renderer:transform(cloneMat)
        self._cloneInstance:draw(renderer)
        renderer:restore()
      end
    end
  end
end

return function(): Node<PathCloner>
  return {
    usePathMode = false,
    
    pathArtwork = late(),
    pathNodeName = "",
    drawPath = true,

    cloneArtwork = late(),
    clones = 5,
    percentStart = 0,
    percentEnd = 100,
    slide = 0,
    loop = true,
    invert = false,
    
    countX = 1,
    countY = 1,
    spiralMode = false,
    offsetX = 0,
    offsetY = 0,
    rotationStep = 0,
    centerX = 0,
    centerY = 0,

    baseScale = 1.0,
    scaleStepX = 0,
    scaleStepY = 0,

    baseRotation = 0,
    rotationStepX = 0,
    rotationStepY = 0,

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
