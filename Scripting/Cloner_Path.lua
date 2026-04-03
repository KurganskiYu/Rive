-- Artboard Path Cloner Node Script

type CloneData = {
  num: Property<number>
}

type PathCloner = {
  pathArtwork: Input<Artboard>,
  pathAnimation: Input<string>,
  pathNodeName: Input<string>,
  drawPath: Input<boolean>,

  cloneArtwork: Input<Artboard>,
  clones: Input<number>,
  percentStart: Input<number>,
  percentEnd: Input<number>,
  slide: Input<number>,
  loop: Input<boolean>,
  invert: Input<boolean>,
  offset: Input<number>,
  startScale: Input<number>,
  endScale: Input<number>,
  startRotation: Input<number>,
  endRotation: Input<number>,
  pathRotation: Input<number>,
  orientAlongCurve: Input<boolean>,

  _pathPaint: Paint,
  _pathInstance: Artboard?,
  _pathAnimationInst: Animation?,
  _currentAnimName: string?,
  _cloneInstances: { Artboard },
  _lastCloneCount: number,
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

  if self._pathInstance and self.pathAnimation and self.pathAnimation ~= "" then
    if not self._pathAnimationInst or self._currentAnimName ~= self.pathAnimation then
      self._pathAnimationInst = self._pathInstance:animation(self.pathAnimation)
      self._currentAnimName = self.pathAnimation
    end
  elseif self._pathAnimationInst and (not self.pathAnimation or self.pathAnimation == "") then
    self._pathAnimationInst = nil
    self._currentAnimName = nil
  end

  if self._pathAnimationInst then
    self._pathAnimationInst:advance(seconds)
  end

  -- Sync main view model common properties to the path instance
  if self._pathInstance and self._context then
    local mainVM = self._context:viewModel()
    local pathVM: any = (self._pathInstance :: any).data
    if mainVM and pathVM then
      local roundProp = mainVM:getNumber("round")
      if roundProp and pathVM.round then
        (pathVM.round :: Property<number>).value = roundProp.value
      end

      local sizeXProp = mainVM:getNumber("sizeX")
      if sizeXProp and pathVM.sizeX then
        (pathVM.sizeX :: Property<number>).value = sizeXProp.value
      end

      local sizeYProp = mainVM:getNumber("sizeY")
      if sizeYProp and pathVM.sizeY then
        (pathVM.sizeY :: Property<number>).value = sizeYProp.value
      end
    end
  end

  -- Advance the path artboard every frame so world transforms are computed
  if self._pathInstance then
    self._pathInstance:advance(seconds)
  end

  local targetStrCount = math.max(1, math.floor(self.clones or 5))

  if not self.cloneArtwork then
    self._cloneInstances = {}
    self._lastCloneCount = 0
  elseif self.cloneArtwork and self._lastCloneCount ~= targetStrCount then
    self._cloneInstances = {}
    for i = 1, targetStrCount do
      local inst = self.cloneArtwork:instance()
      
      -- Access data loosely to avoid strict typecast errors on the Artboard type
      local vm: any = (inst :: any).data
      if vm and vm.num then
        (vm.num :: Property<number>).value = i - 1
      end
      
      table.insert(self._cloneInstances, inst)
    end
    self._lastCloneCount = targetStrCount
  end

  for _, clone in ipairs(self._cloneInstances) do
    if clone then
      clone:advance(seconds)
    end
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
  if not self._pathInstance or not self._cloneInstances or #self._cloneInstances == 0 then return end

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
    elseif cmd.type == "quadTo" then
      dummyPath:quadTo(cmd[1], cmd[2])
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

  local pPercentStart = self.percentStart or 0
  local pPercentEnd = self.percentEnd or 100
  
  local startPct = math.clamp(pPercentStart, 0, 100)
  local endPct = math.clamp(pPercentEnd, 0, 100)
  
  local tStart = startPct / 100.0
  local tEnd = endPct / 100.0
  
  local n = math.max(1, math.floor(self.clones))

  for i = 0, n - 1 do
    local t = if n > 1 then i / (n - 1) else 0

    if self.invert then
      t = 1.0 - t
    end
    
    -- Map normalized t (0-1) to the restricted range between startPct and endPct
    local mapped_t = tStart + t * (tEnd - tStart)
    
    local dist = mapped_t * totalLength
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
    
    local offsetVal = self.offset or 0
    local normalX, normalY = -tan.y, tan.x
    local offsetX = normalX * offsetVal
    local offsetY = normalY * offsetVal

    local cloneMat =
      xform
      * Mat2D.withTranslation(pos.x + offsetX, pos.y + offsetY)
      * Mat2D.withRotation(final_angle)
      * Mat2D.withScale(current_scale, current_scale)

    renderer:save()
    renderer:transform(cloneMat)
    local cloneInst = self._cloneInstances[i + 1]
    if cloneInst then
      cloneInst:draw(renderer)
    end
    renderer:restore()
  end
end

return function(): Node<PathCloner>
  return {
    pathArtwork = late(),
    pathNodeName = "",
    pathAnimation = "",
    drawPath = true,

    cloneArtwork = late(),
    clones = 5,
    percentStart = 0,
    percentEnd = 100,
    slide = 0,
    loop = true,
    invert = false,
    offset = 0,
    startScale = 1.0,
    endScale = 1.0,
    startRotation = 0,
    endRotation = 0,
    pathRotation = 0,
    orientAlongCurve = true,
    _pathPaint = Paint.new(),
    _pathInstance = nil,
    _pathAnimationInst = nil,
    _currentAnimName = nil,
    _cloneInstances = {},
    _lastCloneCount = 0,
    _context = nil,

    init = init,
    advance = advance,
    draw = draw,
  }
end
