-- A squircle is a shape that blends between a square and a circle
-- using superellipse formula: |x/a|^n + |y/b|^n = 1
-- where n controls the "squareness" (n=2 is circle, n→∞ is square)

local function addSquircle(
  path: Path,
  x: number,
  y: number,
  width: number,
  height: number,
  n: number -- power parameter (typically 4 for a nice squircle)
)
  local a = width / 2
  local b = height / 2
  local segments = 64 -- number of segments to approximate the curve

  local function superellipsePoint(t: number): Vector
    local angle = t * math.pi * 2
    local cosAngle = math.cos(angle)
    local sinAngle = math.sin(angle)

    -- Superellipse formula
    local px = math.pow(math.abs(cosAngle), 2 / n)
      * a
      * (cosAngle >= 0 and 1 or -1)
    local py = math.pow(math.abs(sinAngle), 2 / n)
      * b
      * (sinAngle >= 0 and 1 or -1)

    return Vector.xy(px + x, py + y)
  end

  -- Start at t=0
  local firstPoint = superellipsePoint(0)
  path:moveTo(firstPoint)

  -- Draw the squircle using cubic bezier approximation
  for i = 1, segments do
    local t = i / segments
    local point = superellipsePoint(t)
    path:lineTo(point)
  end

  print(path:measure().length)

  path:close()
end

type Squircle = {
  width: Input<number>,
  height: Input<number>,
  color: Input<Color>,
  stroke: Input<number>,
  strokeColor: Input<Color>,

  path: Path,
  fillPaint: Paint,
  strokePaint: Paint,
  context: Context,
}

function init(self: Squircle, context: Context): boolean
  self.context = context

  self.fillPaint = Paint.with({
    style = 'fill',
    color = self.color,
  })

  self.strokePaint = Paint.with({
    style = 'stroke',
    color = self.strokeColor,
    thickness = self.stroke,
  })

  addSquircle(self.path, 0, 0, self.width, self.height, 4)
  return true
end

function advance(self: Squircle, seconds: number): boolean
  return false
end

function update(self: Squircle)
  -- Reset and rebuild the path with current properties
  self.path:reset()
  addSquircle(self.path, 0, 0, self.width, self.height, 4)

  -- Update paint properties
  self.fillPaint.color = self.color
  self.strokePaint.color = self.strokeColor
  self.strokePaint.thickness = self.stroke

  -- Mark for redraw
  self.context:markNeedsUpdate()
end

function draw(self: Squircle, renderer: Renderer)
  -- Draw fill first
  if self.color ~= 0 then
    renderer:drawPath(self.path, self.fillPaint)
  end

  -- Draw stroke on top
  if self.stroke > 0 then
    renderer:drawPath(self.path, self.strokePaint)
  end
end

return function(): Node<Squircle>
  return {
    width = 100,
    height = 100,
    color = 0xFF4488FF, -- default blue fill
    stroke = 2, -- default stroke width
    strokeColor = 0xFF000000, -- default black stroke
    path = Path.new(),
    fillPaint = Paint.new(),
    strokePaint = Paint.new(),
    context = late(),
    init = init,
    advance = advance,
    update = update,
    draw = draw,
  }
end
