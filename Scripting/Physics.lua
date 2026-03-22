-- Physics.lua
-- Separated Physics Module for Position-Based Dynamics
local Physics = {}

local GRID_HASH_X = 73856093
local GRID_HASH_Y = 19349663
local msqrt = math.sqrt
local mfloor = math.floor

export type Particle = {
  id: number,
  x: number,
  y: number,
  prevX: number,
  prevY: number,
  vx: number,
  vy: number,
  cx: number,
  cy: number,
  colRadius: number,
  sleeping: boolean,
  isOuter: boolean,
  escaped: boolean,
  nextInCell: Particle?,
}

export type Grid = { [number]: Particle }

function Physics.buildGrid(particles: { Particle }, cellSize: number): Grid
  local grid: Grid = {}
  local invCell = 1.0 / cellSize
  for i = 1, #particles do
    local p = particles[i]
    local ix = mfloor((p.x + 100000) * invCell)
    local iy = mfloor((p.y + 100000) * invCell)
    p.cx = ix
    p.cy = iy
    local key = ix * GRID_HASH_X + iy * GRID_HASH_Y
    p.nextInCell = grid[key]
    grid[key] = p
  end
  return grid
end

function Physics.solveCollisions(grid: Grid, p: Particle, stiffness: number?, selId: number?)
  local cx, cy = p.cx, p.cy
  local pId = p.id
  local pRadius = p.colRadius
  local st = stiffness or 0.8

  for nx = cx - 1, cx + 1 do
    for ny = cy - 1, cy + 1 do
      local nKey = nx * GRID_HASH_X + ny * GRID_HASH_Y
      local other: Particle? = grid[nKey]

      while other do
          if other.id > pId and other.isOuter == p.isOuter then
          local totalRad = pRadius + other.colRadius
          local dx = other.x - p.x
          local dy = other.y - p.y
          local distSq = dx * dx + dy * dy

          if distSq < totalRad * totalRad and distSq > 0.0001 then
            local dist = msqrt(distSq)
            local totalPen = (totalRad - dist) * st

            local factor = totalPen / dist
            local moveX = dx * factor
            local moveY = dy * factor

            local pStatic = (pId == selId)
            local oStatic = (other.id == selId)

            if pStatic and not oStatic then
              other.x = other.x + moveX
              other.y = other.y + moveY
            elseif oStatic and not pStatic then
              p.x = p.x - moveX
              p.y = p.y - moveY
            elseif not pStatic and not oStatic then
              local halfX, halfY = moveX * 0.5, moveY * 0.5
              p.x = p.x - halfX
              p.y = p.y - halfY
              other.x = other.x + halfX
              other.y = other.y + halfY
            end

            -- Only wake up if it's dynamic physics (stiffness < 1.0), not relax mode
            if st < 1.0 then
              if not pStatic then p.sleeping = false end
              if not oStatic then other.sleeping = false end
            end
          end
        end
        other = other.nextInCell
      end
    end
  end
end

function Physics.applyCircularBoundary(p: Particle, centerX: number, centerY: number, radius: number, friction: number?, isOuter: boolean?)
  local dx = p.x - centerX
  local dy = p.y - centerY
  local distSq = dx * dx + dy * dy
  local fr = friction or 0.1

  if isOuter then
    if not p.escaped then
      return
    end

    local minDist = radius + p.colRadius
    if distSq < minDist * minDist then
      -- It is inside the allowed outer boundary (which means it's pushed outside the circle)
      local dist = msqrt(distSq)
      if dist < 0.0001 then
        dist = 0.0001
        dx = 1
        dy = 0
      end
      local pushRel = minDist / dist
      p.x = centerX + dx * pushRel
      p.y = centerY + dy * pushRel

      local moveX = p.x - p.prevX
      local moveY = p.y - p.prevY
      p.x = p.x - moveX * fr
      p.y = p.y - moveY * fr
    end
  else
    local maxDist = radius - p.colRadius

    if maxDist < 0 then
      -- Particle is too big or circle is too small, force it towards center safely
      p.x = centerX
      p.y = centerY
      return
    end

    if distSq > maxDist * maxDist and distSq > 0.0001 then
      local dist = msqrt(distSq)
      local pushRel = maxDist / dist

      p.x = centerX + dx * pushRel
      p.y = centerY + dy * pushRel

      -- Ground friction (tangential dampening)
      local moveX = p.x - p.prevX
      local moveY = p.y - p.prevY
      p.x = p.x - moveX * fr
      p.y = p.y - moveY * fr
    end
  end
end

function Physics.applyRectangularBoundary(p: Particle, centerX: number, centerY: number, width: number, height: number, friction: number?)
  local fr = friction or 0.1
  local halfW = width * 0.5
  local halfH = height * 0.5
  
  local minX = centerX - halfW + p.colRadius
  local maxX = centerX + halfW - p.colRadius
  local minY = centerY - halfH + p.colRadius
  local maxY = centerY + halfH - p.colRadius
  
  local corrected = false
  
  if p.x < minX then
    p.x = minX
    corrected = true
  elseif p.x > maxX then
    p.x = maxX
    corrected = true
  end
  
  if p.y < minY then
    p.y = minY
    corrected = true
  elseif p.y > maxY then
    p.y = maxY
    corrected = true
  end
  
  if corrected then
      local moveX = p.x - p.prevX
      local moveY = p.y - p.prevY
      p.x = p.x - moveX * fr
      p.y = p.y - moveY * fr
  end
end

return Physics
