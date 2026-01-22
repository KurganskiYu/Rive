type WaterSurface = {
  path: Path,
  waveHeight: Input<number>,
  periodWidth: Input<number>,
  depth: Input<number>,
  time: number,
}

function init(self: WaterSurface): boolean
  self.time = 0
  return true
end

function updatePath(self: WaterSurface)
  local segments: number = 150 -- More segments for smoother curves

  -- Reset the path for redrawing
  self.path:reset()

  -- Multiple waves with different frequencies and speeds for realistic sloshing
  local waves = {
    -- {frequency, speed, amplitude_multiplier, phase_offset}
    { 1.5, 1.2, 0.4, 0 }, -- Primary slow slosh
    { 2.5, -0.8, 0.3, 1.5 }, -- Secondary counter-slosh
    { 4, 1.5, 0.15, 0.7 }, -- Medium frequency ripple
    { 6, -2.0, 0.1, 2.1 }, -- Faster ripple
    { 8, 2.5, 0.05, 3.3 }, -- High frequency detail
  }

  -- Store the top wave points
  local topPoints: { Vector } = {}

  -- Calculate all the top wave points
  for i = 0, segments do
    local t: number = i / segments
    local x: number = -self.periodWidth / 2 + t * self.periodWidth
    local y: number = 0

    -- Sum all waves at this point
    for _, wave in waves do
      local freq: number = wave[1]
      local speed: number = wave[2]
      local amp: number = wave[3]
      local offset: number = wave[4]

      local angle: number = (t * freq * 2 * math.pi)
        + (self.time * speed + offset) * math.pi
      y = y + self.waveHeight * amp * math.sin(angle)
    end

    table.insert(topPoints, Vector.xy(x, y))
  end

  -- Start at the first top point
  self.path:moveTo(topPoints[1])

  -- Draw the top surface (left to right)
  for i = 2, #topPoints do
    self.path:lineTo(topPoints[i])
  end

  -- Draw the right side going down to the fixed bottom depth
  local rightX: number = self.periodWidth / 2
  self.path:lineTo(Vector.xy(rightX, self.depth))

  -- Draw the bottom (right to left) at the fixed depth
  local leftX: number = -self.periodWidth / 2
  self.path:lineTo(Vector.xy(leftX, self.depth))

  -- Draw the left side going up (which closes the path)
  self.path:close()
end

function advance(self: WaterSurface, seconds: number): boolean
  self.time = self.time + seconds
  updatePath(self)
  return true
end

function draw(self: WaterSurface, renderer: Renderer)
  -- Draw filled water shape
  local fillPaint = Paint.with({
    style = 'fill',
    color = 0xFF4DA6FF, -- Water blue color
  })
  renderer:drawPath(self.path, fillPaint)
end

return function(): Node<WaterSurface>
  return {
    path = Path.new(),
    waveHeight = 50,
    periodWidth = 500,
    depth = 300,
    time = 0,
    init = init,
    advance = advance,
    draw = draw,
  }
end
