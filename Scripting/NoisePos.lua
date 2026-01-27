-- NoisePosition: Simple shake generator

type NoisePositionNode = {
    amplitude: Input<number>,
    speed: Input<number>,
    roughness: Input<number>,
    octaves: Input<number>,
    artboard: Input<Artboard>,
    instance: Artboard,
    time: number,
    offsetX: number,
    offsetY: number,
    seedX: number,
    seedY: number,
}

-- Optimization: Cache math functions for performance
local mfloor = math.floor
local msin = math.sin
local mcos = math.cos
local twopi = 6.28318530718

local function randomGradient(ix: number, iy: number): (number, number)
    local random = msin(ix * 12.9898 + iy * 78.233) * 43758.5453
    local val = random - mfloor(random)
    local angle = val * twopi
    return mcos(angle), msin(angle)
end

local function dotGridGradient(ix: number, iy: number, dx: number, dy: number): number
    local gx, gy = randomGradient(ix, iy)
    return gx * dx + gy * dy
end

local function perlin2D(x: number, y: number): number
    local x0 = mfloor(x)
    local y0 = mfloor(y)
    local x1 = x0 + 1
    local y1 = y0 + 1

    local dx0 = x - x0
    local dy0 = y - y0
    local dx1 = dx0 - 1
    local dy1 = dy0 - 1
    
    -- Quintic interpolation
    local sx = dx0 * dx0 * dx0 * (dx0 * (dx0 * 6 - 15) + 10)
    local sy = dy0 * dy0 * dy0 * (dy0 * (dy0 * 6 - 15) + 10)
    
    local n0 = dotGridGradient(x0, y0, dx0, dy0)
    local n1 = dotGridGradient(x1, y0, dx1, dy0)
    local ix0 = n0 + sx * (n1 - n0)

    n0 = dotGridGradient(x0, y1, dx0, dy1)
    n1 = dotGridGradient(x1, y1, dx1, dy1)
    local ix1 = n0 + sx * (n1 - n0)

    return ix0 + sy * (ix1 - ix0)
end

local function fbm(x: number, y: number, rough: number, octaves: number): number
    local total = 0
    local amplitude = 1
    local maxValue = 0
    local freq = 0.5 

    for i = 1, octaves do
        total = total + perlin2D(x * freq, y * freq) * amplitude
        maxValue = maxValue + amplitude
        amplitude = amplitude * rough
        freq = freq * 2
    end

    return (total / maxValue) * 1.5
end

local function init(self: NoisePositionNode, context: Context): boolean
    self.time = 0
    self.offsetX = 0
    self.offsetY = 0
    self.seedX = math.random() * 1000
    self.seedY = math.random() * 1000
    self.instance = self.artboard:instance()
    return true
end

local function advance(self: NoisePositionNode, seconds: number): boolean
    local amp = if self.amplitude ~= 0 then self.amplitude else 10
    local spd = if self.speed ~= 0 then self.speed else 1
    local rough = if self.roughness ~= 0 then self.roughness else 0.5
    local octaves = if self.octaves > 0 then mfloor(self.octaves) else 3
    
    self.time = self.time + seconds * spd
    
    self.offsetX = fbm(self.time, self.seedX, rough, octaves) * amp
    self.offsetY = fbm(self.time, self.seedY, rough, octaves) * amp
    
    self.instance:advance(seconds)
    
    return true
end

local function draw(self: NoisePositionNode, renderer: Renderer)
    renderer:save()
    renderer:transform(Mat2D.withTranslation(self.offsetX, self.offsetY))
    self.instance:draw(renderer)
    renderer:restore()
end

return function(): Node<NoisePositionNode>
    return {
        amplitude = 10,
        speed = 1,
        roughness = 0.5,
        octaves = 3,
        artboard = late(),
        instance = late(),
        time = 0,
        offsetX = 0,
        offsetY = 0,
        seedX = 0,
        seedY = 0,
        init = init,
        advance = advance,
        draw = draw,
    }
end