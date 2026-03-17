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

function Physics.solveCollisions(grid: Grid, p: Particle, stiffness: number?)
  local cx, cy = p.cx, p.cy
  local pId = p.id
  local pRadius = p.colRadius
  local pSleeping = p.sleeping
  local st = stiffness or 0.8

  for nx = cx - 1, cx + 1 do
    for ny = cy - 1, cy + 1 do
      local nKey = nx * GRID_HASH_X + ny * GRID_HASH_Y
      local other: Particle? = grid[nKey]

      while other do
        if other.id > pId then
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

            local oSleeping = other.sleeping
            if not pSleeping and not oSleeping then
              local halfX, halfY = moveX * 0.5, moveY * 0.5
              p.x = p.x - halfX
              p.y = p.y - halfY
              other.x = other.x + halfX
              other.y = other.y + halfY
            elseif not pSleeping and oSleeping then
              p.x = p.x - moveX
              p.y = p.y - moveY
              -- Natural wake-up applied via velocity integration later
              other.sleeping = false
            elseif pSleeping and not oSleeping then
              other.x = other.x + moveX
              other.y = other.y + moveY
              p.sleeping = false
            else
              -- Both sleeping but overlapping (can happen during growth)
              local halfX, halfY = moveX * 0.5, moveY * 0.5
              p.x = p.x - halfX
              p.y = p.y - halfY
              other.x = other.x + halfX
              other.y = other.y + halfY
              p.sleeping = false
              other.sleeping = false
            end
          end
        end
        other = other.nextInCell
      end
    end
  end
end

function Physics.applyCircularBoundary(p: Particle, centerX: number, centerY: number, radius: number, friction: number?)
  local dx = p.x - centerX
  local dy = p.y - centerY
  local distSq = dx * dx + dy * dy
  local maxDist = radius - p.colRadius
  local fr = friction or 0.1

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
    p.x = p.x - moveX * fr
  end
end

return Physics
