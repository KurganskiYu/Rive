-- Round Corners with Bezier Support Path Effect

local STEPS = 16

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
    length: number,
    cum_lens: {number}
}

local function build_curve(p0: Vector, p1: Vector, p2: Vector, p3: Vector): BezierCurve
    local c = {
        p0 = p0, p1 = p1, p2 = p2, p3 = p3,
        length = 0,
        cum_lens = {}
    }
    c.cum_lens[1] = 0
    local prev = p0
    local len = 0
    for i = 1, STEPS do
        local t = i / STEPS
        local pt = bezier_eval(p0, p1, p2, p3, t)
        local d = distance(prev, pt)
        len = len + d
        c.cum_lens[i + 1] = len
        prev = pt
    end
    c.length = len
    return c
end

local function get_t_for_distance(c: BezierCurve, target_d: number): number
    if target_d <= 0.0001 then return 0 end
    if target_d >= c.length - 0.0001 then return 1 end
    for i = 1, STEPS do
        if target_d <= c.cum_lens[i+1] then
            local d0 = c.cum_lens[i]
            local d1 = c.cum_lens[i+1]
            local segment_d = d1 - d0
            local local_t = 0
            if segment_d > 0.00001 then
                local_t = (target_d - d0) / segment_d
            end
            return (i - 1 + local_t) / STEPS
        end
    end
    return 1
end

local function get_tangent_backward_from_end(p0: Vector, p1: Vector, p2: Vector, p3: Vector): Vector
    local pts = {p0, p1, p2, p3}
    for i = 3, 1, -1 do
        local dx = pts[i].x - pts[4].x
        local dy = pts[i].y - pts[4].y
        local l = math.sqrt(dx*dx + dy*dy)
        if l > 0.001 then return Vector.xy(dx/l, dy/l) end
    end
    return Vector.xy(0,0)
end

local function get_tangent_forward_from_start(p0: Vector, p1: Vector, p2: Vector, p3: Vector): Vector
    local pts = {p0, p1, p2, p3}
    for i = 2, 4 do
        local dx = pts[i].x - pts[1].x
        local dy = pts[i].y - pts[1].y
        local l = math.sqrt(dx*dx + dy*dy)
        if l > 0.001 then return Vector.xy(dx/l, dy/l) end
    end
    return Vector.xy(0,0)
end

local function get_tangent_out(pts: {Vector}): Vector
    for i = 3, 1, -1 do
        local dx = pts[4].x - pts[i].x
        local dy = pts[4].y - pts[i].y
        local l = math.sqrt(dx*dx + dy*dy)
        if l > 0.001 then return Vector.xy(dx/l, dy/l) end
    end
    return Vector.xy(0,0)
end

local function get_tangent_in(pts: {Vector}): Vector
    for i = 2, 4 do
        local dx = pts[i].x - pts[1].x
        local dy = pts[i].y - pts[1].y
        local l = math.sqrt(dx*dx + dy*dy)
        if l > 0.001 then return Vector.xy(dx/l, dy/l) end
    end
    return Vector.xy(0,0)
end

type RoundCorners = {
  radius: Input<number>,
  smoothing: Input<number>,
  adaptiveSmoothing: Input<boolean>,
  _hash: number | nil,
  _rad: number | nil,
  _sm: number | nil,
  _adp: boolean | nil,
  _path: PathData | nil
}

type Subpath = {
  curves: {BezierCurve},
  is_closed: boolean
}

type CornerData = { L_clamped: number, theta: number, phi: number }

local function update(self: RoundCorners, inPath: PathData): PathData
  local r = self.radius
  if r < 0 then r = 0 end
  
  local sm = self.smoothing or 0
  local adp = self.adaptiveSmoothing or false
  
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

  if self._hash == h and self._rad == r and self._sm == sm and self._adp == adp and self._path then
      return self._path
  end
  self._hash = h
  self._rad = r
  self._sm = sm
  self._adp = adp

  if r <= 0.001 then 
      self._path = inPath
      return inPath 
  end
  
  local subpaths: {Subpath} = {}
  local curr_curves: {BezierCurve} = {}
  local curr_pt: Vector | nil = nil
  local first_pt: Vector | nil = nil
  
  local function push_subpath(closed: boolean)
      if #curr_curves > 0 then
          table.insert(subpaths, {curves = curr_curves, is_closed = closed})
      end
      curr_curves = {}
  end
  
  for i = 1, #inPath do
      local cmd = inPath[i]
      if cmd.type == 'moveTo' then
          push_subpath(false)
          curr_pt = cmd[1]
          first_pt = cmd[1]
      elseif cmd.type == 'lineTo' then
          if curr_pt ~= nil then
              local pt = cmd[1]
              if distance(curr_pt, pt) > 0.001 then
                  local p1 = lerp(curr_pt, pt, 1/3)
                  local p2 = lerp(curr_pt, pt, 2/3)
                  table.insert(curr_curves, build_curve(curr_pt, p1, p2, pt))
                  curr_pt = pt
              end
          end
      elseif cmd.type == 'cubicTo' then
          if curr_pt ~= nil then
              local pt = cmd[3]
              table.insert(curr_curves, build_curve(curr_pt, cmd[1], cmd[2], pt))
              curr_pt = pt
          end
      elseif cmd.type == 'close' then
          if curr_pt ~= nil and first_pt ~= nil then
              if distance(curr_pt, first_pt) > 0.001 then
                  local pt = first_pt
                  local p1 = lerp(curr_pt, pt, 1/3)
                  local p2 = lerp(curr_pt, pt, 2/3)
                  table.insert(curr_curves, build_curve(curr_pt, p1, p2, pt))
              end
          end
          push_subpath(true)
          curr_pt = nil
          first_pt = nil
      end
  end
  push_subpath(false)
  
  local outPath = Path.new()
  
  for s_idx = 1, #subpaths do
      local sub = subpaths[s_idx]
      local curves = sub.curves
      local n = #curves
      
      if n == 1 then
          if sub.is_closed then
              outPath:moveTo(curves[1].p0)
              outPath:cubicTo(curves[1].p1, curves[1].p2, curves[1].p3)
              outPath:close()
          else
              outPath:moveTo(curves[1].p0)
              outPath:cubicTo(curves[1].p1, curves[1].p2, curves[1].p3)
          end
      elseif n > 1 then
          local L_start: {number} = {}
          local L_end: {number} = {}
          local corners: {CornerData | nil} = {}
          
          for i = 1, n do
              L_start[i] = 0
              L_end[i] = 0
              corners[i] = nil
          end
          
          local num_joints = n - 1
          if sub.is_closed then num_joints = n end
          
          for i = 1, num_joints do
              local prev_idx = i
              local next_idx = i + 1
              if next_idx > n then next_idx = 1 end
              
              local prev_c = curves[prev_idx]
              local next_c = curves[next_idx]
              
              local d1 = get_tangent_backward_from_end(prev_c.p0, prev_c.p1, prev_c.p2, prev_c.p3)
              local d2 = get_tangent_forward_from_start(next_c.p0, next_c.p1, next_c.p2, next_c.p3)
              
              local len1 = math.sqrt(d1.x*d1.x + d1.y*d1.y)
              local len2 = math.sqrt(d2.x*d2.x + d2.y*d2.y)
              
              if len1 > 0.5 and len2 > 0.5 then
                  local dot = d1.x * d2.x + d1.y * d2.y
                  if dot < -1.0 then dot = -1.0 elseif dot > 1.0 then dot = 1.0 end
                  local theta = math.acos(dot)
                  
                  if theta > 0.001 and theta < 3.141 then
                      local half_theta = theta / 2.0
                      local tan_half = math.tan(half_theta)
                      local L = r / tan_half
                      
                      local gap = 0.05
                      local max_L_prev = (prev_c.length / 2.0) - gap
                      if max_L_prev < 0 then max_L_prev = 0 end
                      local max_L_next = (next_c.length / 2.0) - gap
                      if max_L_next < 0 then max_L_next = 0 end
                      
                      local L_clamped = L
                      if max_L_prev < L_clamped then L_clamped = max_L_prev end
                      if max_L_next < L_clamped then L_clamped = max_L_next end
                      
                      L_end[prev_idx] = L_clamped
                      L_start[next_idx] = L_clamped
                      corners[i] = { L_clamped = L_clamped, theta = theta, phi = math.pi - theta }
                  end
              end
          end
          
          local kept_curves: {{Vector}} = {}
          for i = 1, n do
              local c = curves[i]
              local t_start = get_t_for_distance(c, L_start[i])
              local t_end = get_t_for_distance(c, c.length - L_end[i])
              if t_start > t_end then
                  local mid = (t_start + t_end) / 2.0
                  t_start = mid
                  t_end = mid
              end
              
              local _, right = split_bezier(c.p0, c.p1, c.p2, c.p3, t_start)
              local t_rel = 1.0
              if t_start < 1.0 then
                  t_rel = (t_end - t_start) / (1.0 - t_start)
                  if t_rel < 0.0 then t_rel = 0.0 elseif t_rel > 1.0 then t_rel = 1.0 end
              end
              local M_left, _ = split_bezier(right[1], right[2], right[3], right[4], t_rel)
              kept_curves[i] = M_left
          end
          
          outPath:moveTo(kept_curves[1][1])
          
          for i = 1, n do
              local c_kept = kept_curves[i]
              
              outPath:cubicTo(c_kept[2], c_kept[3], c_kept[4])
              
              if i < n or sub.is_closed then
                  local corner = corners[i]
                  local next_idx = i + 1
                  if next_idx > n then next_idx = 1 end
                  
                  if corner ~= nil then
                      local next_kept = kept_curves[next_idx]
                      local A = c_kept[4]
                      local B = next_kept[1]
                      
                      local T_A = get_tangent_out(c_kept)
                      local T_B = get_tangent_in(next_kept)
                      
                      local R_eff = corner.L_clamped * math.tan(corner.theta / 2.0)
                      local base_D_c = R_eff * (4.0 / 3.0) * math.tan(corner.phi / 4.0)
                      
                      -- Adaptive scaling: mapped based on degree (~5 deg = 3.0 scale, ~120 deg = 1.0 scale)
                      local adaptive_scale = 1.0
                      if self.adaptiveSmoothing ~= false then
                          local deg = corner.theta * (180.0 / math.pi)
                          if deg < 120.0 then
                              adaptive_scale = 1.0 + 2.0 * ((120.0 - deg) / 115.0)
                          end
                      end
                      
                      local smooth_factor = (self.smoothing or 1.0) * adaptive_scale
                      local D_c = base_D_c * smooth_factor
                      
                      local C_A = Vector.xy(A.x + T_A.x * D_c, A.y + T_A.y * D_c)
                      local C_B = Vector.xy(B.x - T_B.x * D_c, B.y - T_B.y * D_c)
                      
                      outPath:cubicTo(C_A, C_B, B)
                  else
                      if distance(c_kept[4], kept_curves[next_idx][1]) > 0.001 then
                          outPath:lineTo(kept_curves[next_idx][1])
                      end
                  end
              end
          end
          if sub.is_closed then
              outPath:close()
          end
      end
  end
  
  self._path = outPath
  return outPath
end

return function(): PathEffect<RoundCorners>
  return {
    radius = 20,
    smoothing = 1.0,
    adaptiveSmoothing = true,
    update = update,
  }
end
