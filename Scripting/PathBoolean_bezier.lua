-- Path Boolean Union & Subtract with Bezier Curves
-- Applied as a PathEffect

local STEPS = 64

local function distance(p1: Vector, p2: Vector): number
  local dx = p1.x - p2.x
  local dy = p1.y - p2.y
  return math.sqrt(dx * dx + dy * dy)
end

local function lerp(a: Vector, b: Vector, t: number): Vector
    return Vector.xy(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
end

local function bezier_eval(p0: Vector, p1: Vector, p2: Vector, p3: Vector, t: number): Vector
    local mt = 1 - t
    local mt2 = mt * mt
    local t2 = t * t
    local a = mt2 * mt
    local b = 3 * mt2 * t
    local c = 3 * mt * t2
    local d = t2 * t
    return Vector.xy(
        a * p0.x + b * p1.x + c * p2.x + d * p3.x,
        a * p0.y + b * p1.y + c * p2.y + d * p3.y
    )
end

-- De Casteljau split to subdivide Bezier at a specific parameter t
local function split_bezier(p0: Vector, p1: Vector, p2: Vector, p3: Vector, t: number)
    local p01 = lerp(p0, p1, t)
    local p12 = lerp(p1, p2, t)
    local p23 = lerp(p2, p3, t)
    
    local p012 = lerp(p01, p12, t)
    local p123 = lerp(p12, p23, t)
    
    local p0123 = lerp(p012, p123, t)
    
    return {p0, p01, p012, p0123}, {p0123, p123, p23, p3}
end

type BezierCurve = {
    p0: Vector, p1: Vector, p2: Vector, p3: Vector,
    poly_id: number,
    id: number,
    splits: {number},
    flat_points: {Vector}
}

-- Builds a Bezier curve abstraction and its flattened points
local function build_curve(p0: Vector, p1: Vector, p2: Vector, p3: Vector): BezierCurve
    local c = {
        p0 = p0, p1 = p1, p2 = p2, p3 = p3,
        poly_id = 0,
        id = 0,
        splits = {},
        flat_points = {}
    }
    for i = 0, STEPS do
        local t = i / STEPS
        c.flat_points[i+1] = bezier_eval(p0, p1, p2, p3, t)
    end
    return c
end

-- Intersects two segments, returning local parameters u,v in [0, 1] if intersecting
local function seg_intersect_t(p1: Vector, p2: Vector, p3: Vector, p4: Vector): (number | nil, number | nil)
    local d = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x)
    if d == 0 then return nil, nil end
    local u = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / d
    local v = ((p1.x - p3.x) * (p1.y - p2.y) - (p1.y - p3.y) * (p1.x - p2.x)) / d
    if u >= -0.0001 and u <= 1.0001 and v >= -0.0001 and v <= 1.0001 then
        return u, v
    end
    return nil, nil
end

-- Ray-casting algorithm adapted for our curves' flattened segments
local function is_point_in_poly(pt: Vector, poly_curves: {BezierCurve}): boolean
    local x = pt.x
    local y = pt.y + 0.000187 -- offset prevents hitting straight horizontal edges identically
    local inside = false
    for k = 1, #poly_curves do
        local c = poly_curves[k]
        for i = 1, STEPS do
            local xi = c.flat_points[i].x
            local yi = c.flat_points[i].y
            local xj = c.flat_points[i+1].x
            local yj = c.flat_points[i+1].y
            
            local intersect = ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            if intersect then
                inside = not inside
            end
        end
    end
    return inside
end

type PathBoolean = {
  operation: Input<number>, -- 0 for Union, 1 for Subtract
  _hash: number | nil,
  _op: number | nil,
  _path: PathData | nil
}

function update(self: PathBoolean, inPath: PathData): PathData
  local h = #inPath
  for i = 1, #inPath do
      local cmd = inPath[i]
      local ct = cmd.type
      if ct == 'moveTo' or ct == 'lineTo' then
          h = h + cmd[1].x * i + cmd[1].y * (i + 1)
      elseif ct == 'cubicTo' then
          h = h + cmd[1].x * i + cmd[1].y + cmd[2].x * (i + 1) + cmd[2].y + cmd[3].x * (i + 2) + cmd[3].y
      end
  end
  local op = self.operation or 0
  if self._hash == h and self._op == op and self._path then
      return self._path
  end
  self._hash = h
  self._op = op

  local polys: {{BezierCurve}} = {}
  local currentPoly: {BezierCurve} | nil = nil
  local currPt = Vector.xy(0,0)
  local firstPt = Vector.xy(0,0)

  local function push_poly()
      if currentPoly ~= nil and #currentPoly > 0 then
          if distance(currPt, firstPt) > 0.001 then
              local p0 = currPt
              local p3 = firstPt
              local p1 = lerp(p0, p3, 1/3)
              local p2 = lerp(p0, p3, 2/3)
              table.insert(currentPoly, build_curve(p0, p1, p2, p3))
          end
          table.insert(polys, currentPoly)
      end
      currentPoly = nil
  end

  -- 1. Extract paths and uniformize straight segments into cubic Beziers
  for i = 1, #inPath do
    local cmd = inPath[i]
    if cmd.type == 'moveTo' then
        push_poly()
        currentPoly = {}
        currPt = cmd[1]
        firstPt = cmd[1]
    elseif cmd.type == 'lineTo' then
        if currentPoly ~= nil then
            if distance(currPt, cmd[1]) > 0.001 then
                local p0 = currPt
                local p3 = cmd[1]
                local p1 = lerp(p0, p3, 1/3)
                local p2 = lerp(p0, p3, 2/3)
                table.insert(currentPoly, build_curve(p0, p1, p2, p3))
                currPt = cmd[1]
            end
        end
    elseif cmd.type == 'cubicTo' then
        if currentPoly ~= nil then
            local p0 = currPt
            local p1 = cmd[1]
            local p2 = cmd[2]
            local p3 = cmd[3]
            table.insert(currentPoly, build_curve(p0, p1, p2, p3))
            currPt = cmd[3]
        end
    elseif cmd.type == 'close' then
        push_poly()
    end
  end
  push_poly()
  
  if #polys < 2 then return inPath end

  -- 2. Build explicit curves
  local all_curves: {BezierCurve} = {}
  local curve_id = 1
  for p_id = 1, #polys do
      for i = 1, #polys[p_id] do
          local c = polys[p_id][i]
          c.poly_id = p_id
          c.id = curve_id
          table.insert(all_curves, c)
          curve_id = curve_id + 1
      end
  end

  -- 3. Find intersections and populate split points
  for i = 1, #all_curves do
      local c1 = all_curves[i]
      for j = i + 1, #all_curves do
          local c2 = all_curves[j]
          if c1.poly_id ~= c2.poly_id then
              for s1 = 1, STEPS do
                  local A1 = c1.flat_points[s1]
                  local B1 = c1.flat_points[s1+1]
                  for s2 = 1, STEPS do
                      local A2 = c2.flat_points[s2]
                      local B2 = c2.flat_points[s2+1]
                      
                      local u, v = seg_intersect_t(A1, B1, A2, B2)
                      if u and v then
                          local t1 = (s1 - 1 + u) / STEPS
                          local t2 = (s2 - 1 + v) / STEPS
                          
                          if t1 > 0.005 and t1 < 0.995 then
                              table.insert(c1.splits, t1)
                          end
                          if t2 > 0.005 and t2 < 0.995 then
                              table.insert(c2.splits, t2)
                          end
                      end
                  end
              end
          end
      end
  end

  -- Deduplicate split points per curve
  for i = 1, #all_curves do
      local c = all_curves[i]
      if #c.splits > 0 then
          table.sort(c.splits)
          local dedup = {c.splits[1]}
          for k = 2, #c.splits do
              if c.splits[k] - dedup[#dedup] > 0.01 then
                  table.insert(dedup, c.splits[k])
              end
          end
          c.splits = dedup
      end
  end

  -- 4. Split curves into pieces and filter depending on Boolean rules
  type KeptPiece = {p0: Vector, p1: Vector, p2: Vector, p3: Vector, poly_id: number}
  local kept_pieces: {KeptPiece} = {}

  for i = 1, #all_curves do
      local c = all_curves[i]
      local pieces: {{Vector}} = {}
      local remaining_pts = {c.p0, c.p1, c.p2, c.p3}
      local prev_t = 0
      
      for k = 1, #c.splits do
          local t_orig = c.splits[k]
          local t_rel = (t_orig - prev_t) / (1 - prev_t)
          if t_rel < 0 then t_rel = 0 elseif t_rel > 1 then t_rel = 1 end
          local left, right = split_bezier(remaining_pts[1], remaining_pts[2], remaining_pts[3], remaining_pts[4], t_rel)
          table.insert(pieces, left)
          remaining_pts = right
          prev_t = t_orig
      end
      table.insert(pieces, remaining_pts)
      
      for k = 1, #pieces do
          local pts = pieces[k]
          local mid = bezier_eval(pts[1], pts[2], pts[3], pts[4], 0.5123)
          
          local keep = false
          local reverse = false
          
          if self.operation == 1 then
              -- SUBTRACT
              if c.poly_id == 1 then
                  local inside_clip = false
                  for p_id = 2, #polys do
                      if is_point_in_poly(mid, polys[p_id]) then
                          inside_clip = true
                          break
                      end
                  end
                  keep = not inside_clip
              else
                  local inside_sub = is_point_in_poly(mid, polys[1])
                  local inside_other_clip = false
                  for p_id = 2, #polys do
                      if p_id ~= c.poly_id and is_point_in_poly(mid, polys[p_id]) then
                          inside_other_clip = true
                          break
                      end
                  end
                  keep = inside_sub and not inside_other_clip
                  reverse = true
              end
          else
              -- UNION (0)
              local is_inside_other = false
              for p_id = 1, #polys do
                  if p_id ~= c.poly_id then
                      if is_point_in_poly(mid, polys[p_id]) then
                          is_inside_other = true
                          break
                      end
                  end
              end
              keep = not is_inside_other
          end
          
          if keep and distance(pts[1], pts[4]) > 0.05 then
              if reverse then
                  table.insert(kept_pieces, {p0=pts[4], p1=pts[3], p2=pts[2], p3=pts[1], poly_id=c.poly_id})
              else
                  table.insert(kept_pieces, {p0=pts[1], p1=pts[2], p2=pts[3], p3=pts[4], poly_id=c.poly_id})
              end
          end
      end
  end

  -- 5. Reassemble kept pieces into continuous paths
  local newPath = Path.new()
  local used: {boolean} = {}
  for i = 1, #kept_pieces do used[i] = false end

  for i = 1, #kept_pieces do
      if not used[i] then
          local start_piece = kept_pieces[i]
          used[i] = true
          newPath:moveTo(start_piece.p0)
          newPath:cubicTo(start_piece.p1, start_piece.p2, start_piece.p3)
          
          local curr_end = start_piece.p3
          local found_next = true
          
          while found_next do
              found_next = false
              local best_j = -1
              local best_d = 20.0 -- allow bridging Bezier linearization drifts
              local best_rev = false
              
              for j = 1, #kept_pieces do
                  if not used[j] then
                      local p = kept_pieces[j]
                      local d0 = distance(curr_end, p.p0)
                      local d3 = distance(curr_end, p.p3) + 0.005 -- slight penalty to prefer correct winding flow
                      
                      if d0 < best_d then
                          best_d = d0
                          best_j = j
                          best_rev = false
                      end
                      
                      if d3 < best_d then
                          best_d = d3
                          best_j = j
                          best_rev = true
                      end
                  end
              end
              
              if best_j ~= -1 then
                  local p = kept_pieces[best_j]
                  if best_rev then
                      newPath:cubicTo(p.p2, p.p1, p.p0)
                      curr_end = p.p0
                  else
                      newPath:cubicTo(p.p1, p.p2, p.p3)
                      curr_end = p.p3
                  end
                  used[best_j] = true
                  found_next = true
              end
          end
          
          if distance(curr_end, start_piece.p0) < 20.0 then
              newPath:close()
          end
      end
  end

  self._path = newPath
  return newPath
end

return function(): PathEffect<PathBoolean>
  return {
    operation = 0,
    update = update,
  }
end
