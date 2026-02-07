-- Metaball Path Effect

-- Generates a Metaball isosurface around the vertices of the input path.

local mfloor = math.floor

local _mrandom = math.random

local _min, max = math.min, math.max

local sqrt = math.sqrt

-- Localize Vector constructor for tight loop performance

local vectorXY = Vector.xy

type Point = {

  x: number,

  y: number,

  r: number,

  rSq: number

}



type MetaballEffect = {

  radius: Input<number>,

  threshold: Input<number>,

  resolution: Input<number>, -- Max grid dimension

  smoothness: Input<number>, 

  resampleDist: Input<number>, -- Distance between points for output resampling

  inputDensity: Input<number>, -- Distance to sample points along input path (0 = vertices only)

  

}



local function lerp(a: number, b: number, t: number): number

    return a + (b - a) * t

end



-- Edge ID generators

local function idH(i: number, j: number): string return i .. "x" .. j end 

local function idV(i: number, j: number): string return i .. "y" .. j end 



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
    
    if not isClosed then
        local lastP = points[cnt]
        local lastInserted = newPoints[#newPoints]
        if lastP then
            if lastInserted then
                if lastInserted:distance(lastP) > 0.1 then table.insert(newPoints, lastP) end
            else
                table.insert(newPoints, lastP)
            end
        end
    end
    return newPoints
end

-- Chaikin's Corner Cutting Algorithm 

local function smoothChaikin(points: {Vector}, iterations: number, isClosed: boolean): {Vector}
  if iterations < 1 or #points < 3 then return points end
  
  local currObj = points
  for iter = 1, iterations do
      local nextObj: {Vector} = {}
      local cnt = #currObj
      
      local firstP = currObj[1]
      if not isClosed and firstP then table.insert(nextObj, firstP) end
      
      local numSegs = isClosed and cnt or (cnt - 1)
      
      for i = 1, numSegs do
          local p0 = currObj[i]
          local p1 = currObj[(i % cnt) + 1] 
          
          if p0 and p1 then
            local q = vectorXY(p0.x * 0.75 + p1.x * 0.25, p0.y * 0.75 + p1.y * 0.25)
            local r = vectorXY(p0.x * 0.25 + p1.x * 0.75, p0.y * 0.25 + p1.y * 0.75)
            table.insert(nextObj, q)
            table.insert(nextObj, r)
          end
      end
      
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
    return vectorXY(lerp(x1, x2, t), lerp(y1, y2, t))
end

local function update(self: MetaballEffect, path: PathData, node: NodeReadData): PathData
  local outPath = Path.new()
  
  -- 1. Extract Points from Input Path
  local rawPoints: {Point} = {}
  local inputStep = self.inputDensity
  local px, py = 0, 0
  
  local function addP(x: number, y: number)
      table.insert(rawPoints, { x = x, y = y, r = self.radius, rSq = self.radius * self.radius })
  end

  for i = 1, #path do
      local cmd = path[i]
      if cmd.type == 'moveTo' then
          px, py = cmd[1].x, cmd[1].y
          addP(px, py)
      elseif cmd.type == 'lineTo' then
          local p = cmd[1]
          if inputStep > 0.1 then
              local dist = sqrt((p.x-px)^2 + (p.y-py)^2)
              if dist > inputStep then
                  local num = mfloor(dist / inputStep)
                  for k = 1, num do
                      local t = k / (num + 1)
                      addP(lerp(px, p.x, t), lerp(py, p.y, t))
                  end
              end
          end
          addP(p.x, p.y)
          px, py = p.x, p.y
      elseif cmd.type == 'cubicTo' or cmd.type == 'quadTo' then
          local p = cmd[#cmd] -- End point
          -- Simple subdivision for curves based on linear distance approx
          if inputStep > 0.1 then
              local dist = sqrt((p.x-px)^2 + (p.y-py)^2)
              if dist > inputStep then
                  local num = mfloor(dist / inputStep)
                  -- Note: This linearizes the curve between keyframes for the emitter points, which is usually sufficient for metaballs
                  for k = 1, num do
                      local t = k / (num + 1)
                      addP(lerp(px, p.x, t), lerp(py, p.y, t))
                  end
              end
          end
          addP(p.x, p.y)
          px, py = p.x, p.y
      elseif cmd.type == 'close' then
          -- Loop logic is handled visually by the metaballs merging
      end
  end

  if #rawPoints == 0 then return outPath end

  -- 2. Setup Grid Bounds
  local pad = self.radius * 2.5
  local minX, minY = rawPoints[1].x, rawPoints[1].y
  local maxX, maxY = minX, minY
  
  for k = 2, #rawPoints do
      local p = rawPoints[k]
      if p.x < minX then minX = p.x end
      if p.x > maxX then maxX = p.x end
      if p.y < minY then minY = p.y end
      if p.y > maxY then maxY = p.y end
  end
  
  minX = minX - pad
  minY = minY - pad
  maxX = maxX + pad
  maxY = maxY + pad
  
  local w = maxX - minX
  local h = maxY - minY
  
  local res = mfloor(self.resolution)
  if res < 5 then res = 5 end 
  if res > 150 then res = 150 end 

  local maxDim = max(w, h)
  local cellSize = maxDim / res
  if cellSize < 0.1 then cellSize = 0.1 end

  local cols = mfloor(w / cellSize) + 1
  local rows = mfloor(h / cellSize) + 1
  -- Cap grid size
  if cols > 150 then cols = 150 end
  if rows > 150 then rows = 150 end
  
  local dx = cellSize
  local dy = cellSize
  
  local thresh = self.threshold * 0.01

  local gridWidth = cols + 1
  local values: { [number]: number } = {} -- Sparse array explictly typed

  local function getX(i: number) return minX + i * dx end
  local function getY(j: number) return minY + j * dy end

  local segments: { [string]: SegmentData } = {} 
  local parents: { [string]: string } = {}
  local hasSegments = false
  local smoothSteps = mfloor(self.smoothness)
  local rDist = self.resampleDist

  -- 3. Additive Rasterization
  for k = 1, #rawPoints do
    local p = rawPoints[k]
    local effectiveR = p.r * 2 
    
    local startI = mfloor((p.x - effectiveR - minX) / dx)
    local endI   = mfloor((p.x + effectiveR - minX) / dx) + 1
    local startJ = mfloor((p.y - effectiveR - minY) / dy)
    local endJ   = mfloor((p.y + effectiveR - minY) / dy) + 1
    
    if startI < 0 then startI = 0 end
    if startJ < 0 then startJ = 0 end
    if endI > cols then endI = cols end
    if endJ > rows then endJ = rows end
    
    local rSq = p.rSq
    local pxLoc = p.x
    local pyLoc = p.y
    
    for j = startJ, endJ do
      local y = getY(j)
      local dY = y - pyLoc
      local dY2 = dY * dY
      local rowOffset = j * gridWidth
      
      for i = startI, endI do
        local x = getX(i)
        local dX = x - pxLoc
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

  local function addSeg(idFrom: string, p1: Vector, idTo: string, p2: Vector) 
      if smoothSteps > 0 then
          segments[idFrom] = { nextID = idTo, startPt = p1, endPt = p2 }
          parents[idTo] = idFrom 
          hasSegments = true
      else
          outPath:moveTo(p1)
          outPath:lineTo(p2)
      end
  end

  -- 4. Marching Squares
  for j = 0, rows - 1 do
    local y = getY(j)
    local y2 = getY(j+1)
    
    for i = 0, cols - 1 do
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
        local idT = idH(i, j)
        local idR = idV(i+1, j)
        local idB = idH(i, j+1)
        local idL = idV(i, j)

        -- Calculate points on demand to save partial performance
        -- Note: Direction must strictly follow "Solid on Left" rule to ensure segments link up.

        -- Case 1: BL(1). B->L
        if case == 1 then
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idB, pB, idL, pL)
        elseif case == 2 then
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            addSeg(idR, pR, idB, pB)
        elseif case == 3 then
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idR, pR, idL, pL)
        elseif case == 4 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            addSeg(idT, pT, idR, pR)
        elseif case == 5 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            local centerVal = (v0 + v1 + v2 + v3) * 0.25
            if centerVal >= thresh then
                 addSeg(idT, pT, idL, pL)
                 addSeg(idB, pB, idR, pR)
            else
                 addSeg(idT, pT, idR, pR)
                 addSeg(idB, pB, idL, pL)
            end
        elseif case == 6 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            addSeg(idT, pT, idB, pB)
        elseif case == 7 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idT, pT, idL, pL)
        elseif case == 8 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idL, pL, idT, pT)
        elseif case == 9 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            addSeg(idB, pB, idT, pT)
        elseif case == 10 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            local centerVal = (v0 + v1 + v2 + v3) * 0.25
            if centerVal >= thresh then
                 addSeg(idR, pR, idT, pT)
                 addSeg(idL, pL, idB, pB)
            else
                 addSeg(idL, pL, idT, pT)
                 addSeg(idR, pR, idB, pB)
            end
        elseif case == 11 then
            pT = getEdgePoint(x, y, v0, x2, y, v1, thresh)
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            addSeg(idR, pR, idT, pT)
        elseif case == 12 then
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pL = getEdgePoint(x, y, v0, x, y2, v3, thresh)
            addSeg(idL, pL, idR, pR)
        elseif case == 13 then
            pR = getEdgePoint(x2, y, v1, x2, y2, v2, thresh)
            pB = getEdgePoint(x, y2, v3, x2, y2, v2, thresh)
            addSeg(idB, pB, idR, pR)
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
      local seedKey: string? = next(segments)
      
      while seedKey ~= nil do
          local currKey: string = seedKey -- Guaranteed not nil by loop condition
          local visitedReverse: { [string]: boolean } = {} 
          
          while parents[currKey] and segments[parents[currKey]] do
              local pKey = parents[currKey]
              if visitedReverse[pKey] then break end
              visitedReverse[pKey] = true
              currKey = pKey
          end
          
          local loopPoints = {}
          local pStartKey = currKey
          local isClosed = false
          
          if segments[currKey] then
             table.insert(loopPoints, segments[currKey].startPt)
          end

          local traceKey: string? = currKey
          while traceKey do
              local seg = segments[traceKey]
              if not seg then break end 
              
              table.insert(loopPoints, seg.endPt)
              segments[traceKey] = nil 
              
              traceKey = seg.nextID
              
              if traceKey == pStartKey then 
                  isClosed = true 
                  break 
              end
          end
          
          if isClosed then
            table.remove(loopPoints)
          end

          if rDist > 0.1 then
              loopPoints = resamplePolyline(loopPoints, rDist, isClosed)
          end

          local smoothed = smoothChaikin(loopPoints, smoothSteps, isClosed)
          
          if #smoothed > 1 then
              outPath:moveTo(smoothed[1])
              for k = 2, #smoothed do
                  outPath:lineTo(smoothed[k])
              end
              if isClosed then outPath:close() end
          end
          
          seedKey = next(segments)
      end
  end
  return outPath
end

local _context: Context? = nil
local function init(self: MetaballEffect, context: Context)
  _context = context
  return true
end

local function advance(self: MetaballEffect, dt: number)
  -- Always dirty to respond to input path changes
  if _context then _context:markNeedsUpdate() end
  return true
end

return function(): PathEffect<MetaballEffect>
  return {
    radius = 50,     
    threshold = 100, 
    resolution = 60, -- Grid Resolution
    smoothness = 2, 
    resampleDist = 5, -- Output resampling
    inputDensity = 50, -- Input path sampling (0 = vertices only)
    init = init,
    advance = advance,
    update = update,
  }
end







