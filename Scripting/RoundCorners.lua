-- Round Corners PathEffect

local function distance(p1: Vector, p2: Vector): number
  local dx = p1.x - p2.x
  local dy = p1.y - p2.y
  return math.sqrt(dx * dx + dy * dy)
end

type Subpath = {
  points: {Vector},
  is_closed: boolean
}

type RoundCorners = {
  radius: Input<number>
}

local function handle_corner(outPath: Path, p_prev: Vector, p_curr: Vector, p_next: Vector, r: number)
  local v1x = p_prev.x - p_curr.x
  local v1y = p_prev.y - p_curr.y
  local l1 = math.sqrt(v1x * v1x + v1y * v1y)
  
  local v2x = p_next.x - p_curr.x
  local v2y = p_next.y - p_curr.y
  local l2 = math.sqrt(v2x * v2x + v2y * v2y)
  
  if l1 < 0.001 or l2 < 0.001 then
    outPath:lineTo(p_curr)
    return
  end
  
  local d1x = v1x / l1
  local d1y = v1y / l1
  local d2x = v2x / l2
  local d2y = v2y / l2
  
  local dot = d1x * d2x + d1y * d2y
  if dot < -1 then dot = -1 end
  if dot > 1 then dot = 1 end
  local theta = math.acos(dot)
  
  if theta < 0.001 or theta > 3.141 then
     outPath:lineTo(p_curr)
     return
  end
  
  local half_theta = theta / 2.0
  local tan_half = math.tan(half_theta)
  
  local L = r / tan_half
  
  local max_L = l1 / 2.0
  if (l2 / 2.0) < max_L then
      max_L = l2 / 2.0
  end
  
  local L_clamped = L
  if max_L < L then
      L_clamped = max_L
  end
  
  local r_eff = L_clamped * tan_half
  
  local phi = math.pi - theta
  local c_dist = r_eff * (4.0 / 3.0) * math.tan(phi / 4.0)
  
  local t1x = p_curr.x + d1x * L_clamped
  local t1y = p_curr.y + d1y * L_clamped
  
  local t2x = p_curr.x + d2x * L_clamped
  local t2y = p_curr.y + d2y * L_clamped
  
  local c1x = t1x - d1x * c_dist
  local c1y = t1y - d1y * c_dist
  
  local c2x = t2x - d2x * c_dist
  local c2y = t2y - d2y * c_dist
  
  outPath:lineTo(Vector.xy(t1x, t1y))
  outPath:cubicTo(Vector.xy(c1x, c1y), Vector.xy(c2x, c2y), Vector.xy(t2x, t2y))
end

local function get_pt(pts: {Vector}, i: number, n: number): Vector
  local idx = i
  while idx < 1 do idx = idx + n end
  while idx > n do idx = idx - n end
  return pts[idx]
end

local function update(self: RoundCorners, inPath: PathData): PathData
  local r = self.radius
  if r < 0 then r = 0 end
  
  local subpaths: {Subpath} = {}
  local current_points: {Vector} | nil = nil
  
  for i = 1, #inPath do
    local cmd = inPath[i]
    if cmd.type == 'moveTo' then
      if current_points ~= nil then
        local cp = current_points :: {Vector}
        if #cp > 0 then
          table.insert(subpaths, { points = cp, is_closed = false })
        end
      end
      current_points = { cmd[1] }
    elseif cmd.type == 'lineTo' then
      if current_points ~= nil then
        local cp = current_points :: {Vector}
        local lastPt = cp[#cp]
        local newPt = cmd[1]
        if distance(lastPt, newPt) > 0.001 then
          table.insert(cp, newPt)
        end
      end
    elseif cmd.type == 'close' then
      if current_points ~= nil then
        local cp = current_points :: {Vector}
        if #cp > 0 then
           if #cp > 1 and distance(cp[1], cp[#cp]) < 0.001 then
              table.remove(cp)
           end
           table.insert(subpaths, { points = cp, is_closed = true })
        end
      end
      current_points = nil
    end
  end
  
  if current_points ~= nil then
    local cp = current_points :: {Vector}
    if #cp > 0 then
      table.insert(subpaths, { points = cp, is_closed = false })
    end
  end
  
  if r == 0 then
    return inPath
  end
  
  local outPath = Path.new()
  
  for i = 1, #subpaths do
    local sub = subpaths[i]
    local pts = sub.points
    local n = #pts
    
    if n == 2 then
      outPath:moveTo(pts[1])
      outPath:lineTo(pts[2])
      if sub.is_closed then
         outPath:close()
      end
    elseif n > 2 then
      if sub.is_closed then
         local midX = (pts[1].x + pts[2].x) / 2.0
         local midY = (pts[1].y + pts[2].y) / 2.0
         outPath:moveTo(Vector.xy(midX, midY))
         
         for j = 2, n + 1 do
           local p_prev = get_pt(pts, j - 1, n)
           local p_curr = get_pt(pts, j, n)
           local p_next = get_pt(pts, j + 1, n)
           handle_corner(outPath, p_prev, p_curr, p_next, r)
         end
         outPath:close()
      else
         outPath:moveTo(pts[1])
         for j = 2, n - 1 do
           local p_prev = pts[j - 1]
           local p_curr = pts[j]
           local p_next = pts[j + 1]
           handle_corner(outPath, p_prev, p_curr, p_next, r)
         end
         outPath:lineTo(pts[n])
      end
    end
  end
  
  return outPath
end

return function(): PathEffect<RoundCorners>
  return {
    radius = 20,
    update = update,
  }
end
