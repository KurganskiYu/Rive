-- Metaball Node
-- Optimized for Rive Lua Runtime using Additive Rasterization.
-- Calculates field only within effective radius of each point.

local mfloor = math.floor
local mrandom = math.random
local min, max = math.min, math.max
-- Localize Vector constructor for tight loop performance
local vectorXY = Vector.xy

type Point = {
  x: number,
  y: number,
  r: number,
  rSq: number
}

type MetaballNode = {
  width: Input<number>,
  height: Input<number>,
  count: Input<number>,
  radius: Input<number>,
  threshold: Input<number>,
  seed: Input<number>,
  resolution: Input<number>,
  smoothness: Input<number>, -- New parameter for subdivision smoothing
  resampleDist: Input<number>, -- New: Distance between points for resampling
  color: Input<Color>,
  strokeThickness: Input<number>,
  throttle: Input<number>, -- Frames to skip between updates
  
  points: { Point },
  path: Path,
  paint: Paint,
  context: Context,
  
  frameCounter: number,
  needsRebuild: boolean,
}

local function lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

-- Edge ID generators for precise topology tracking instead of coordinate hashing
local function idH(i: number, j: number): string return i .. "x" .. j end -- Horizontal edge
local function idV(i: number, j: number): string return i .. "y" .. j end -- Vertical edge

type SegmentData = {
    nextID: string,
    startPt: Vector,
    endPt: Vector
}

-- Resample polyline to have equidistant points
local function resamplePolyline(points: {Vector}, step: number, isClosed: boolean): {Vector}
    if #points < 2 or step <= 0.1 then return points end
    
    local newPoints: {Vector} = {}
    local firstInd = points[1]
    if firstInd then table.insert(newPoints, firstInd) end
    
    local nextDist = step
    local accumulated = 0
    
    local cnt = #points
    -- If closed, iterate count times (including wrap edge)
    -- If open, iterate count-1 times
    local segCount = isClosed and cnt or (cnt - 1)
    
    for i = 1, segCount do
        local pStart = points[i]
        local pEnd = points[(i % cnt) + 1]
        
        if pStart and pEnd then
            local d = pStart:distance(pEnd)
            
            while accumulated + d >= nextDist do
                local ratio = (nextDist - accumulated) / d
                local nx = lerp(pStart.x, pEnd.x, ratio)
                local ny = lerp(pStart.y, pEnd.y, ratio)
                table.insert(newPoints, vectorXY(nx, ny))
                nextDist = nextDist + step
            end
            accumulated = accumulated + d
        end
    end
    
    -- For open paths, ensure we include the very last point
    if not isClosed then
        local lastP = points[cnt]
        local lastInserted = newPoints[#newPoints]
        
        if lastP then
            if lastInserted then
                -- If we aren't extremely close to the end, add it
                if lastInserted:distance(lastP) > 0.1 then
                    table.insert(newPoints, lastP)
                end
            else
                table.insert(newPoints, lastP)
            end
        end
    end
    
    return newPoints
end

-- Chaikin's Corner Cutting Algorithm 
-- Handle closed loops correctly by removing duplicate end point and wrapping indices
local function smoothChaikin(points: {Vector}, iterations: number, isClosed: boolean): {Vector}
  if iterations < 1 or #points < 3 then return points end
  
  local currObj = points
  for iter = 1, iterations do
      local nextObj: {Vector} = {}
      local cnt = #currObj
      
      -- If open, preserve first point
      local firstP = currObj[1]
      if not isClosed and firstP then table.insert(nextObj, firstP) end
      
      local numSegs = isClosed and cnt or (cnt - 1)
      
      for i = 1, numSegs do
          local p0 = currObj[i]
          local p1 = currObj[(i % cnt) + 1] 
          
          if p0 and p1 then
            -- Cut corners at 25% and 75%
            local q = vectorXY(p0.x * 0.75 + p1.x * 0.25, p0.y * 0.75 + p1.y * 0.25)
            local r = vectorXY(p0.x * 0.25 + p1.x * 0.75, p0.y * 0.25 + p1.y * 0.75)
            
            table.insert(nextObj, q)
            table.insert(nextObj, r)
          end
      end
      
      -- If open, preserve last point
      local lastP = currObj[cnt]
      if not isClosed and lastP then table.insert(nextObj, lastP) end
      
      currObj = nextObj
  end
  return currObj
end

-- Linear interpolation to find threshold crossing on an edge
local function getEdgePoint(x1: number, y1: number, v1: number, x2: number, y2: number, v2: number, threshold: number): Vector
    local t = 0.5
    local diff = v2 - v1
    if diff ~= 0 then
        t = (threshold - v1) / diff 
    end
    -- Use localized constructor
    return vectorXY(lerp(x1, x2, t), lerp(y1, y2, t))
end

local function refreshPoints(self: MetaballNode)
  math.randomseed(mfloor(self.seed))
  self.points = {}
  local cnt = mfloor(self.count)
  if cnt < 1 then cnt = 1 end
  
  local w = self.width
  local h = self.height
  local rad = self.radius 
  
  for i = 1, cnt do
    local px = mrandom() * w
    local py = mrandom() * h
    local r = rad * (0.5 + mrandom() * 0.5) 
    table.insert(self.points, { x = px, y = py, r = r, rSq = r * r })
  end
end

local function rebuildMesh(self: MetaballNode)
  local path = self.path
  path:reset()
  
  local points = self.points
  
  -- 2. Setup Grid
  local pad = self.radius * 3 
  local minX = -pad
  local minY = -pad
  local maxX = self.width + pad
  local maxY = self.height + pad
  
  local res = mfloor(self.resolution)
  if res < 5 then res = 5 end 
  if res > 150 then res = 150 end 
  
  local dx = (maxX - minX) / res
  local dy = (maxY - minY) / res
  local thresh = self.threshold * 0.01

  local gridWidth = res + 1
  local values = {} -- Sparse array

  -- Helper to get consistent coordinates from indices
  local function getX(i: number) return minX + i * dx end
  local function getY(j: number) return minY + j * dy end

  -- Store directed edges via logical IDs
  local segments: { [string]: SegmentData } = {} 
  local parents: { [string]: string } = {} -- Reverse map for backtracking to start of open chains
  local hasSegments = false
  local smoothSteps = mfloor(self.smoothness)
  local rDist = self.resampleDist

  -- 3. Additive Rasterization (Optimization)
  for k = 1, #points do
    local p = points[k]
    local effectiveR = p.r * 2.5 
    
    local startI = mfloor((p.x - effectiveR - minX) / dx)
    local endI   = mfloor((p.x + effectiveR - minX) / dx) + 1
    local startJ = mfloor((p.y - effectiveR - minY) / dy)
    local endJ   = mfloor((p.y + effectiveR - minY) / dy) + 1
    
    if startI < 0 then startI = 0 end
    if startJ < 0 then startJ = 0 end
    if endI > res then endI = res end
    if endJ > res then endJ = res end
    
    local rSq = p.rSq
    local px = p.x
    local py = p.y
    
    for j = startJ, endJ do
      local y = getY(j)
      local dY = y - py
      local dY2 = dY * dY
      local rowOffset = j * gridWidth
      
      for i = startI, endI do
        local x = getX(i)
        local dX = x - px
        local d2 = dX * dX + dY2
        if d2 < 0.1 then d2 = 0.1 end
        
        local val = rSq / d2
        if val > 0.05 then
            local idx = rowOffset + i + 1
            values[idx] = (values[idx] or 0) + val
        end
      end
    end
  end

  -- Helper to record segment with topology ID
  local function addSeg(idFrom: string, p1: Vector, idTo: string, p2: Vector) 
      if smoothSteps > 0 then
          segments[idFrom] = { nextID = idTo, startPt = p1, endPt = p2 }
          parents[idTo] = idFrom -- Register parent for backtracking
          hasSegments = true
      else
          path:moveTo(p1)
          path:lineTo(p2)
      end
  end

  -- 4. Marching Squares with Topology IDs
  for j = 0, res - 1 do
    local y = getY(j)
    local y2 = getY(j+1)
    
    for i = 0, res - 1 do
      local x = getX(i)
      local x2 = getX(i+1)

      local idx0 = j * gridWidth + i + 1
      local idx1 = j * gridWidth + (i + 1) + 1
      local idx2 = (j + 1) * gridWidth + (i + 1) + 1
      local idx3 = (j + 1) * gridWidth + i + 1
      
      local v0 = values[idx0] or 0
      local v1 = values[idx1] or 0
      local v2 = values[idx2] or 0
      local v3 = values[idx3] or 0
      
      local case = 0
      if v0 >= thresh then case = case + 8 end 
      if v1 >= thresh then case = case + 4 end 
      if v2 >= thresh then case = case + 2 end 
      if v3 >= thresh then case = case + 1 end 
      
      if case > 0 and case < 15 then
        local pT, pR, pB, pL
        -- Edge IDs
        local idT = idH(i, j)      -- Top
        local idR = idV(i+1, j)    -- Right
        local idB = idH(i, j+1)    -- Bottom
        local idL = idV(i, j)      -- Left

        -- Calculate points on demand to save partial performance
        -- Note: Direction must strictly follow "Solid on Left" rule to ensure segments link up.

        -- Case 1: BL(1). B->L
        if case == 1 then
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idB, pB, idL, pL)

        -- Case 2: BR(2). R->B
        elseif case == 2 then
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            addSeg(idR, pR, idB, pB)

        -- Case 3: BL(1)+BR(2). R->L
        elseif case == 3 then
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idR, pR, idL, pL)

        -- Case 4: TR(4). T->R
        elseif case == 4 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            addSeg(idT, pT, idR, pR)

        -- Case 5: TR(4)+BL(1). Saddle.
        elseif case == 5 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            
            local centerVal = (v0 + v1 + v2 + v3) * 0.25
            if centerVal >= thresh then
                 -- Merged Solids (TR+BL connect): Holes are TL and BR.
                 -- T->L (Encloses TL hole), B->R (Encloses BR hole)
                 addSeg(idT, pT, idL, pL)
                 addSeg(idB, pB, idR, pR)
            else
                 -- Separated Solids: T->R (TR solid), B->L (BL solid)
                 addSeg(idT, pT, idR, pR)
                 addSeg(idB, pB, idL, pL)
            end

        -- Case 6: TR(4)+BR(2). T->B
        elseif case == 6 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            addSeg(idT, pT, idB, pB)

        -- Case 7: All except TL. T->L (Encloses TL hole)
        elseif case == 7 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idT, pT, idL, pL)

        -- Case 8: TL(8). L->T
        elseif case == 8 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idL, pL, idT, pT)

        -- Case 9: TL(8)+BL(1). B->T
        elseif case == 9 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            addSeg(idB, pB, idT, pT)

        -- Case 10: TL(8)+BR(2). Saddle.
        elseif case == 10 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)

            local centerVal = (v0 + v1 + v2 + v3) * 0.25
            if centerVal >= thresh then
                 -- Merged Solids (TL+BR connect): Holes are TR and BL.
                 -- R->T (Encloses TR hole), L->B (Encloses BL hole)
                 addSeg(idR, pR, idT, pT)
                 addSeg(idL, pL, idB, pB)
            else
                 -- Separated Solids: L->T (TL solid), R->B (BR solid)
                 addSeg(idL, pL, idT, pT)
                 addSeg(idR, pR, idB, pB)
            end
            
        -- Case 11: All except TR. R->T (Encloses TR hole)
        elseif case == 11 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            addSeg(idR, pR, idT, pT)

        -- Case 12: TL(8)+TR(4). L->R
        elseif case == 12 then
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idL, pL, idR, pR)

        -- Case 13: All except BR. B->R (Encloses BR hole)
        elseif case == 13 then
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            addSeg(idB, pB, idR, pR)

        -- Case 14: All except BL. L->B (Encloses BL hole)
        elseif case == 14 then
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idL, pL, idB, pB)
        end
      end
    end
  end

  -- 5. Reconstruction & Smoothing
  if hasSegments and smoothSteps > 0 then
      local seedKey = next(segments)
      
      while seedKey ~= nil do
          -- 5a. Find the true start of the chain (Backtracking)
          -- If we pick a segment in the middle of an open chain, we must back up to the start
          -- to avoid splitting the line into two visual parts during smoothing.
          
          local currKey = seedKey
          local visitedReverse: { [string]: boolean } = {} -- Cycle detection
          
          -- Backtrack while there is a parent AND that parent is still valid (not consumed)
          while parents[currKey] and segments[parents[currKey]] do
              local pKey = parents[currKey]
              if visitedReverse[pKey] then 
                  -- Cycle detected (Closed Loop). We can start anywhere in the cycle.
                  break 
              end
              visitedReverse[pKey] = true
              currKey = pKey
          end
          
          -- currKey is now the start of the chain (or valid point in a loop)

          local loopPoints = {}
          local pStartKey = currKey
          local isClosed = false
          
          if segments[currKey] then
             table.insert(loopPoints, segments[currKey].startPt)
          end

          -- Trace forward
          local traceKey: string? = currKey
          while traceKey do
              local seg = segments[traceKey]
              if not seg then break end 
              
              table.insert(loopPoints, seg.endPt)
              segments[traceKey] = nil -- Consume
              
              traceKey = seg.nextID
              
              if traceKey == pStartKey then 
                  isClosed = true 
                  break 
              end
          end
          
          if isClosed then
            -- Remove last duplicate point to prevent knot in smoothing
            table.remove(loopPoints)
          end

          -- 1. Resample (if requested)
          if rDist > 0.1 then
              loopPoints = resamplePolyline(loopPoints, rDist, isClosed)
          end

          -- 2. Smooth
          local smoothed = smoothChaikin(loopPoints, smoothSteps, isClosed)
          
          if #smoothed > 1 then
              path:moveTo(smoothed[1])
              for k = 2, #smoothed do
                  path:lineTo(smoothed[k])
              end
              if isClosed then path:close() end
          end
          
          seedKey = next(segments)
      end
  end
end

local function init(self: MetaballNode, context: Context)
  self.context = context
  self.points = {}
  
  self.path = Path.new()
  self.paint = Paint.with({
    style = 'stroke',
    color = self.color,
    thickness = self.strokeThickness,
    cap = 'round', 
    join = 'round' 
  })
  
  self.frameCounter = 0
  self.needsRebuild = true
  
  -- Force initial build
  refreshPoints(self)
  rebuildMesh(self)
  return true
end

local function update(self: MetaballNode)
  self.needsRebuild = true
end

local function advance(self: MetaballNode, dt: number)
  self.frameCounter = self.frameCounter + 1
  local throttle = mfloor(self.throttle)
  if throttle < 1 then throttle = 1 end

  if self.needsRebuild and (self.frameCounter % throttle == 0) then
      refreshPoints(self)
      rebuildMesh(self)
      
      self.paint.color = self.color
      self.paint.thickness = self.strokeThickness
      
      if self.context then self.context:markNeedsUpdate() end
      self.needsRebuild = false
  end
  return true
end

local function draw(self: MetaballNode, renderer: Renderer)
  renderer:drawPath(self.path, self.paint)
end

return function(): Node<MetaballNode>
  return {
    width = 500,
    height = 500,
    count = 8,
    radius = 50,     
    threshold = 100, 
    seed = 123,
    resolution = 60, 
    smoothness = 2, 
    resampleDist = 5, -- Default resampling distance
    color = 0xFF00FFFF, 
    strokeThickness = 2,
    throttle = 1, 
    
    points = {},
    path = late(),
    paint = late(),
    context = late(),
    
    frameCounter = 0,
    needsRebuild = false,

    init = init,
    advance = advance,
    draw = draw,
    update = update,
  }
end



