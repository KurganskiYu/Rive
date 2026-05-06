-- Path Boolean Union via Segment Intersection and Midpoint Filtering
-- Applied as a PathEffect

local function distance(p1: Vector, p2: Vector): number
  local dx = p1.x - p2.x
  local dy = p1.y - p2.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Find intersection point between two line segments
local function seg_intersect(p1: Vector, p2: Vector, p3: Vector, p4: Vector): Vector | nil
  local d = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x)
  if d == 0 then return nil end
  local t = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / d
  local u = ((p1.x - p3.x) * (p1.y - p2.y) - (p1.y - p3.y) * (p1.x - p2.x)) / d
  -- Strictly inside the segment to avoid endpoint duplication issues
  if t > 0.0001 and t < 0.9999 and u > 0.0001 and u < 0.9999 then
    return Vector.xy(p1.x + t * (p2.x - p1.x), p1.y + t * (p2.y - p1.y))
  end
  return nil
end

-- Ray-casting algorithm to test if a point is inside a polygon
local function is_point_in_poly(pt: Vector, poly: {Vector}): boolean
  local x = pt.x
  local y = pt.y
  local inside = false
  local j = #poly
  for i = 1, #poly do
    local xi = poly[i].x
    local yi = poly[i].y
    local xj = poly[j].x
    local yj = poly[j].y
    
    local intersect = ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
    if intersect then
      inside = not inside
    end
    j = i
  end
  return inside
end

type PathBoolean = {
  operation: Input<number>, -- 0 for Union, 1 for Subtract
}
type Polygon = {Vector}
type Segment = { p1: Vector, p2: Vector, poly_id: number }

-- The update method receives the combined geometry of all sub-paths
function update(self: PathBoolean, inPath: PathData): PathData
  local polys: {Polygon} = {}
  local currentPoly: Polygon | nil = nil
  
  -- 1. Extract polygons from inPath commands
  for i = 1, #inPath do
    local cmd = inPath[i]
    if cmd.type == 'moveTo' then
      if currentPoly ~= nil then
        local p = currentPoly :: Polygon
        if #p > 2 then
          table.insert(polys, p)
        end
      end
      currentPoly = {cmd[1]}
    elseif cmd.type == 'lineTo' then
      if currentPoly ~= nil then
        local p = currentPoly :: Polygon
        local lastPt = p[#p]
        local newPt = cmd[1]
        if distance(lastPt, newPt) > 0.001 then
          table.insert(p, newPt)
        end
      end
    elseif cmd.type == 'close' then
      if currentPoly ~= nil then
        local p = currentPoly :: Polygon
        if #p > 2 then
          table.insert(polys, p)
        end
      end
      currentPoly = nil
    end
  end
  if currentPoly ~= nil then
    local p = currentPoly :: Polygon
    if #p > 2 then
      table.insert(polys, p)
    end
  end
  
  -- Return original path if nothing to union
  if #polys < 2 then 
    return inPath 
  end

  -- 2. Build explicit segments
  local all_segments: {Segment} = {}
  for p_id = 1, #polys do
    local poly = polys[p_id]
    for i = 1, #poly do
      local p1 = poly[i]
      local p2 = poly[i % #poly + 1]
      table.insert(all_segments, { p1 = p1, p2 = p2, poly_id = p_id })
    end
  end

  -- 3. Find intersections and split segments
  local split_segments: {Segment} = {}
  for i = 1, #all_segments do
    local seg = all_segments[i]
    local splits: {Vector} = {}
    for j = 1, #all_segments do
      local other_seg = all_segments[j]
      if seg.poly_id ~= other_seg.poly_id then
        local pt = seg_intersect(seg.p1, seg.p2, other_seg.p1, other_seg.p2)
        if pt then
          table.insert(splits, pt)
        end
      end
    end
    
    -- Sort splits by distance from p1
    table.sort(splits, function(a: Vector, b: Vector): boolean
      return distance(seg.p1, a) < distance(seg.p1, b)
    end)
    
    -- Create sub-segments
    local last_pt = seg.p1
    for k = 1, #splits do
      local pt = splits[k]
      if distance(last_pt, pt) > 0.001 then
        table.insert(split_segments, { p1 = last_pt, p2 = pt, poly_id = seg.poly_id })
      end
      last_pt = pt
    end
    if distance(last_pt, seg.p2) > 0.001 then
      table.insert(split_segments, { p1 = last_pt, p2 = seg.p2, poly_id = seg.poly_id })
    end
  end
  
  -- 4. Filter sub-segments based on the boolean operation
  local kept_segments: {Segment} = {}
  for i = 1, #split_segments do
    local seg = split_segments[i]
    local midX = (seg.p1.x + seg.p2.x) / 2
    local midY = (seg.p1.y + seg.p2.y) / 2
    local midPoint = Vector.xy(midX, midY)
    
    local keep = false
    local reverse = false
    
    if self.operation == 1 then
      -- SUBTRACT: Polygon 1 MINUS Polygon 2..N
      if seg.poly_id == 1 then
        -- Keep subject segments if outside all clip polygons
        local inside_clip = false
        for p_id = 2, #polys do
          if is_point_in_poly(midPoint, polys[p_id]) then
            inside_clip = true
            break
          end
        end
        keep = not inside_clip
      else
        -- Keep clip segments if inside subject polygon and outside other clip polygons
        local inside_sub = is_point_in_poly(midPoint, polys[1])
        local inside_other_clip = false
        for p_id = 2, #polys do
          if p_id ~= seg.poly_id and is_point_in_poly(midPoint, polys[p_id]) then
            inside_other_clip = true
            break
          end
        end
        keep = inside_sub and not inside_other_clip
        reverse = true -- Reverse winding to create holes
      end
    else
      -- UNION (default 0): Keep segments outside ALL other polygons
      local is_inside_other = false
      for p_id = 1, #polys do
        if p_id ~= seg.poly_id then
          if is_point_in_poly(midPoint, polys[p_id]) then
            is_inside_other = true
            break
          end
        end
      end
      keep = not is_inside_other
    end
    
    if keep then
      if reverse then
        table.insert(kept_segments, { p1 = seg.p2, p2 = seg.p1, poly_id = seg.poly_id })
      else
        table.insert(kept_segments, seg)
      end
    end
  end
  
  -- 5. Reassemble kept segments into continuous loops
  local newPath = Path.new()
  local used: {boolean} = {}
  for i = 1, #kept_segments do used[i] = false end
  
  for i = 1, #kept_segments do
    local start_seg = kept_segments[i]
    if not used[i] then
      used[i] = true
      newPath:moveTo(start_seg.p1)
      newPath:lineTo(start_seg.p2)
      
      local curr_pt = start_seg.p2
      local found_next = true
      while found_next do
        found_next = false
        for j = 1, #kept_segments do
          if not used[j] then
            local next_seg = kept_segments[j]
            if distance(curr_pt, next_seg.p1) < 0.01 then
              newPath:lineTo(next_seg.p2)
              curr_pt = next_seg.p2
              used[j] = true
              found_next = true
              break
            elseif distance(curr_pt, next_seg.p2) < 0.01 then
              newPath:lineTo(next_seg.p1) -- Reverse segment
              curr_pt = next_seg.p1
              used[j] = true
              found_next = true
              break
            end
          end
        end
        if distance(curr_pt, start_seg.p1) < 0.01 then
          newPath:close()
          break
        end
      end
    end
  end
  
  return newPath
end

return function(): PathEffect<PathBoolean>
  return {
    operation = 0,
    update = update,
  }
end
