-- Soft Body Physics Simulator (2D XPBD)
-- Simulates pressurized bubbles with collision and gravity.

type Particle = {
    x: number,
    y: number,
    prevX: number,
    prevY: number,
    invMass: number
}

-- NEW: simple 2D point type for helpers (avoids multi-return tuple typing)
type Vec2 = { x: number, y: number }

type Bubble = {
    id: number, -- NEW: 1..4 (used to map per-bubble inputs)
    particles: {Particle},
    restLengths: {number}, -- BASE distances between i and i+1 (multipliers applied in solver)
    restArea: number,      -- BASE signed area (multiplier applied in solver)
    path: Path,
    paint: Paint,
    strokePaint: Paint,

    -- FIX: per-bubble COM marker path (avoid shared mutable Path in draw loop)
    comPath: Path,
}

type SoftBodySim = {
    -- Inputs
    gravity: Input<number>,
    edgeCompliance: Input<number>,
    areaCompliance: Input<number>,
    damping: Input<number>,
    substeps: Input<number>,
    particleRadius: Input<number>,
    throttle: Input<number>,
    constraintIterations: Input<number>,

    collisionDistanceFactor: Input<number>,

    bubbleSegments: Input<number>,
    bubbleRadius: Input<number>, -- kept as fallback/default size
    particleInvMass: Input<number>,
    pressure: Input<number>, -- RENAMED: was restAreaMultiplier
    restLengthMultiplier: Input<number>,

    -- NEW: per-bubble pressure + size
    bubble1Pressure: Input<number>,
    bubble2Pressure: Input<number>,
    bubble3Pressure: Input<number>,
    bubble4Pressure: Input<number>,
    bubble1Size: Input<number>,
    bubble2Size: Input<number>,
    bubble3Size: Input<number>,
    bubble4Size: Input<number>,

    -- NEW: tweening
    startupTweenFrames: Input<number>,

    -- State
    bubbles: {Bubble},
    width: number,
    height: number,
    isInitialized: boolean,
    context: Context,
    boxPath: Path,
    boxPaint: Paint,
    frameCounter: number,

    -- NEW: COM draw helpers
    -- FIX: keep only paint on sim; path is per-bubble now
    comPaint: Paint,

    -- FIX: these caches are used by initBubbles()/advance() and must exist on the type
    _cachedSegments: number,
    _cachedInvMass: number,
    _cachedSize1: number,
    _cachedSize2: number,
    _cachedSize3: number,
    _cachedSize4: number,

    -- (optional legacy/unused caches kept if you want)
    _cachedAreaMult: number,
    _cachedLenMult: number,

    -- NEW: tween state
    _tweens: {[string]: { startValue: number, endValue: number, duration: number, frame: number }},
    _paramOverrides: {[string]: number},

    -- Methods
    initBubbles: (self: SoftBodySim) -> (),
    simulate: (self: SoftBodySim, dt: number) -> (),
    solveConstraints: (self: SoftBodySim, dt: number) -> (),
    updatePaths: (self: SoftBodySim) -> (),

    tweenParam: (self: SoftBodySim, name: string, startValue: number, endValue: number, durationFrames: number) -> (),
    updateTweens: (self: SoftBodySim) -> (),
    getParam: (self: SoftBodySim, name: string, fallback: number) -> (number),
}

-- Math Shortcuts
local msqrt = math.sqrt

local function distSq(x1: number, y1: number, x2: number, y2: number): number
    local dx = x1 - x2
    local dy = y1 - y2
    return dx*dx + dy*dy
end

-- FIX: was referenced but not defined
local function clamp(x: number, lo: number, hi: number): number
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

-- NEW: smooth non-linear easing (smootherstep)
local function smootherstep(t: number): number
    t = clamp(t, 0.0, 1.0)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

-- ADD: used by initBubbles() to compute base (signed) rest area
local function polygonAreaSigned(parts: {Particle}): number
    local n = #parts
    if n < 3 then return 0 end
    local a = 0
    for i = 1, n do
        local j = (i % n) + 1
        local p1 = parts[i]
        local p2 = parts[j]
        a = a + (p1.x * p2.y - p2.x * p1.y)
    end
    return a * 0.5
end

-- ADD: used by initBubbles() to color each bubble
local bubbleColors = {
    Color.rgba(255, 100, 100, 200),
    Color.rgba(100, 255, 100, 200),
    Color.rgba(100, 100, 255, 200),
    Color.rgba(255, 200, 50, 200),
}

-- MOVED UP: typed helpers must be defined before initBubbles()/solveConstraints() use them
local function getBubbleSize(self: SoftBodySim, id: number): number
    if id == 1 then return self.bubble1Size end
    if id == 2 then return self.bubble2Size end
    if id == 3 then return self.bubble3Size end
    return self.bubble4Size
end

local function getBubblePressure(self: SoftBodySim, id: number): number
    if id == 1 then return self.bubble1Pressure end
    if id == 2 then return self.bubble2Pressure end
    if id == 3 then return self.bubble3Pressure end
    return self.bubble4Pressure
end

function tweenParam(self: SoftBodySim, name: string, startValue: number, endValue: number, durationFrames: number)
    local dur = math.floor(durationFrames)
    if dur < 1 then
        self._paramOverrides[name] = endValue
        self._tweens[name] = nil
        return
    end
    self._tweens[name] = { startValue = startValue, endValue = endValue, duration = dur, frame = 0 }
    self._paramOverrides[name] = startValue
end

function updateTweens(self: SoftBodySim)
    local toRemove: {string} = {}
    for name: string, tw in pairs(self._tweens) do
        tw.frame = tw.frame + 1
        local u = tw.frame / tw.duration
        local s = smootherstep(u)
        self._paramOverrides[name] = lerp(tw.startValue, tw.endValue, s)
        if tw.frame >= tw.duration then
            table.insert(toRemove, name)
        end
    end
    for _, name: string in ipairs(toRemove) do
        self._tweens[name] = nil
        -- keep final override value
    end
end

function getParam(self: SoftBodySim, name: string, fallback: number): number
    local v = self._paramOverrides[name]
    if v == nil then return fallback end
    return v
end

-- Initialize 4 Bubbles in a grid configuration (non-intersecting)
function initBubbles(self: SoftBodySim) 
    self.bubbles = {}

    self.width = 500
    self.height = 500

    local numSegments = math.floor(self.bubbleSegments)
    numSegments = math.floor(clamp(numSegments, 3, 128))

    local invMass = clamp(self.particleInvMass, 0, 1000000)

    -- cache params so we can rebuild when changed
    self._cachedSegments = numSegments
    self._cachedInvMass = invMass

    -- NEW: cache per-bubble sizes (fallback to bubbleRadius if unset)
    self._cachedSize1 = clamp((getBubbleSize(self, 1) > 0) and getBubbleSize(self, 1) or self.bubbleRadius, 1, 1000)
    self._cachedSize2 = clamp((getBubbleSize(self, 2) > 0) and getBubbleSize(self, 2) or self.bubbleRadius, 1, 1000)
    self._cachedSize3 = clamp((getBubbleSize(self, 3) > 0) and getBubbleSize(self, 3) or self.bubbleRadius, 1, 1000)
    self._cachedSize4 = clamp((getBubbleSize(self, 4) > 0) and getBubbleSize(self, 4) or self.bubbleRadius, 1, 1000)

    local startPositions = {
        {x = 150, y = 150},
        {x = 350, y = 150},
        {x = 150, y = 350},
        {x = 350, y = 350}
    }

    for b = 1, #startPositions do
        local parts: {Particle} = {}
        local lens: {number} = {}
        local cx, cy = startPositions[b].x, startPositions[b].y

        -- CHANGED: per-bubble size (radius) without self[sizeKey]
        local radius = getBubbleSize(self, b)
        if radius <= 0 then radius = self.bubbleRadius end
        radius = clamp(radius, 1, 1000)

        -- 1. Create Particles in a circle
        for i = 1, numSegments do
            local angle = (i - 1) * (2 * math.pi / numSegments)
            local px = cx + math.cos(angle) * radius
            local py = cy + math.sin(angle) * radius
            table.insert(parts, {
                x = px, y = py,
                prevX = px, prevY = py,
                invMass = invMass,
            })
        end

        -- 2. Calculate Edge Rest Lengths (BASE)
        for i = 1, numSegments do
            local nextIdx = (i % numSegments) + 1
            local p1 = parts[i]
            local p2 = parts[nextIdx]
            local d = msqrt(distSq(p1.x, p1.y, p2.x, p2.y))
            table.insert(lens, d) -- base, multiplier applied in solver
        end

        -- 3. Calculate Rest Area (BASE signed)
        local area = polygonAreaSigned(parts) -- base, multiplier applied in solver

        local fillPaint = Paint.with({
            style = 'fill',
            color = bubbleColors[((b - 1) % #bubbleColors) + 1],
        })
        local strokePaint = Paint.with({
            style = 'stroke',
            thickness = 2,
            color = bubbleColors[((b - 1) % #bubbleColors) + 1],
        })

        table.insert(self.bubbles, {
            id = b, -- NEW
            particles = parts,
            restLengths = lens,
            restArea = area,
            path = Path.new(),
            paint = fillPaint,
            strokePaint = strokePaint,

            -- FIX: allocate a dedicated path for this bubble’s COM marker
            comPath = Path.new(),
        })
    end

    -- Initialize box path
    -- (be defensive in case boxPath wasn't constructed yet)
    self.boxPath = self.boxPath or Path.new()
    self.boxPath:reset()
    self.boxPath:moveTo(Vector.xy(0, 0))
    self.boxPath:lineTo(Vector.xy(self.width, 0))
    self.boxPath:lineTo(Vector.xy(self.width, self.height))
    self.boxPath:lineTo(Vector.xy(0, self.height))
    self.boxPath:close()
    
    self:updatePaths()
    self.isInitialized = true
end

-- XPBD Solver
function solveConstraints(self: SoftBodySim, dt: number)
    if dt <= 0.000001 then return end
    local alphaEdge = self.edgeCompliance / (dt * dt)
    local alphaArea = self.areaCompliance / (dt * dt)
    local pRadius = self.particleRadius

    local width = self.width
    local height = self.height

    local lenMult = clamp(self:getParam("restLengthMultiplier", self.restLengthMultiplier), 0.01, 100.0)

    for _, b in ipairs(self.bubbles) do
        local n = #b.particles

        -- CHANGED: per-bubble pressure (fallback to global pressure) without self[pKey]
        local pFallback = getBubblePressure(self, b.id)
        if pFallback == nil then pFallback = self.pressure end -- defensive; should never be nil
        local pKey = "bubble" .. tostring(b.id) .. "Pressure"
        local pressure = clamp(self:getParam(pKey, pFallback), 0.01, 100.0)

        -- A. Edge Constraints
        for i = 1, n do
            local j = (i % n) + 1
            local p1 = b.particles[i]
            local p2 = b.particles[j]
            local restLen = b.restLengths[i] * lenMult
            
            local dx = p1.x - p2.x
            local dy = p1.y - p2.y
            local d2 = dx*dx + dy*dy
            local d = msqrt(d2)
            
            -- Prevent division by zero
            if d > 0.0001 then
                local w1 = p1.invMass
                local w2 = p2.invMass
                local w = w1 + w2
                if w > 0 then
                    local C = d - restLen
                    local lambda = -C / (w + alphaEdge)
                    
                    local gradX = dx / d
                    local gradY = dy / d
                    
                    local dxMove = gradX * lambda
                    local dyMove = gradY * lambda
                    
                    p1.x = p1.x + dxMove * w1
                    p1.y = p1.y + dyMove * w1
                    p2.x = p2.x - dxMove * w2
                    p2.y = p2.y - dyMove * w2
                end
            end
        end
        
        -- B. Area Constraint
        -- Calculates polygon area and applies gradients to restore restArea
        local currentArea = 0
        for i = 1, n do
            local j = (i % n) + 1
            local p1 = b.particles[i]
            local p2 = b.particles[j]
            currentArea = currentArea + (p1.x * p2.y - p2.x * p1.y)
        end
        currentArea = currentArea * 0.5
        
        -- CHANGED: was (b.restArea * areaMult), now per-bubble pressure
        local C = currentArea - (b.restArea * pressure)

        -- Only process if area compliance is tight enough
        if alphaArea < 1000000 then 
            local sumGradSq = 0
            local gradsX = {}
            local gradsY = {}
            
            -- Compute Gradients for all particles first
            for i = 1, n do
                local prevIdx = (i - 2 + n) % n + 1
                local nextIdx = (i % n) + 1
                local pPrev = b.particles[prevIdx]
                local pNext = b.particles[nextIdx]
                
                -- Gradient of signed polygon area A w.r.t point i
                -- dA/dx_i = 0.5 * (y_{i+1} - y_{i-1})
                -- dA/dy_i = 0.5 * (x_{i-1} - x_{i+1})
                local gx = 0.5 * (pNext.y - pPrev.y)
                local gy = 0.5 * (pPrev.x - pNext.x)
                
                gradsX[i] = gx
                gradsY[i] = gy
                sumGradSq = sumGradSq + b.particles[i].invMass * (gx*gx + gy*gy)
            end
            
            if sumGradSq > 0.000001 then
                local lambda = -C / (sumGradSq + alphaArea)
                for i = 1, n do
                    local p = b.particles[i]
                    p.x = p.x + lambda * gradsX[i] * p.invMass
                    p.y = p.y + lambda * gradsY[i] * p.invMass
                end
            end
        end
        
        -- C. Wall Collisions (Box)
        for i = 1, n do
            local p = b.particles[i]
            -- Simple clamping with radius buffer
            if p.x < pRadius then p.x = pRadius end
            if p.x > width - pRadius then p.x = width - pRadius end
            if p.y < pRadius then p.y = pRadius end
            if p.y > height - pRadius then p.y = height - pRadius end
        end
    end
    
    -- D. Bubble-to-Bubble Collision (ONLY across different bubbles)
    local allParticles: {{ p: Particle, b: number }} = {}
    for bi, b in ipairs(self.bubbles) do
        for _, p in ipairs(b.particles) do
            table.insert(allParticles, { p = p, b = bi })
        end
    end
    
    local count = #allParticles

    -- CHANGED: prevent inter-bubble overlap by enforcing factor >= 1.0 here
    local factor = clamp(self.collisionDistanceFactor, 1.0, 10.0)
    local minDist = (pRadius * 2) * factor
    local minDistSq = minDist * minDist
    local eps = 1e-8

    for i = 1, count do
        for j = i + 1, count do
            local a = allParticles[i]
            local c = allParticles[j]

            if a.b ~= c.b then
                local p1 = a.p
                local p2 = c.p

                local dx = p1.x - p2.x
                local dy = p1.y - p2.y
                local d2 = dx*dx + dy*dy

                if d2 < minDistSq then
                    -- CHANGED: robust normal + mass-weighted positional correction
                    local w1 = p1.invMass
                    local w2 = p2.invMass
                    local w = w1 + w2
                    if w > 0 then
                        local nx, ny, d
                        if d2 > eps then
                            d = msqrt(d2)
                            local invD = 1.0 / d
                            nx = dx * invD
                            ny = dy * invD
                        else
                            -- nearly identical positions; pick a deterministic fallback direction
                            d = 0.0
                            nx, ny = 1.0, 0.0
                        end

                        local pen = minDist - d
                        if pen > 0 then
                            -- C = d - minDist (<= 0), lambda = -C / w = pen / w
                            local lambda = pen / w
                            local corrX = nx * lambda
                            local corrY = ny * lambda

                            p1.x = p1.x + corrX * w1
                            p1.y = p1.y + corrY * w1
                            p2.x = p2.x - corrX * w2
                            p2.y = p2.y - corrY * w2
                        end
                    end
                end
            end
        end
    end
end

function simulate(self: SoftBodySim, dt: number)
    if not self.isInitialized then return end
    if dt <= 0.000001 then return end
    
    local steps = math.floor(self.substeps)
    if steps < 1 then steps = 1 end

    local iters = math.floor(self.constraintIterations) -- NEW
    if iters < 1 then iters = 1 end
    
    local sdt = dt / steps
    
    -- CHANGED: gravity becomes a centric force toward the box center
    local g = self.gravity * 50
    local centerX = self.width * 0.5
    local centerY = self.height * 0.5
    local eps = 1e-6

    local dampingFactor = 1.0 - (self.damping / 100 * 0.1)
    
    for _ = 1, steps do
        for _, b in ipairs(self.bubbles) do
            for _, p in ipairs(b.particles) do
                if p.invMass > 0 then
                    -- Verlet Integration
                    local vx = (p.x - p.prevX) / sdt
                    local vy = (p.y - p.prevY) / sdt
                    
                    -- External Forces (centric "gravity")
                    local dx = centerX - p.x
                    local dy = centerY - p.y
                    local d2 = dx*dx + dy*dy
                    if d2 > eps then
                        local invD = 1.0 / msqrt(d2)
                        local ax = dx * invD * g
                        local ay = dy * invD * g
                        vx = vx + ax * sdt
                        vy = vy + ay * sdt
                    end
                    
                    -- Damping
                    vx = vx * dampingFactor
                    vy = vy * dampingFactor
                    
                    p.prevX = p.x
                    p.prevY = p.y
                    
                    -- Prediction
                    p.x = p.x + vx * sdt
                    p.y = p.y + vy * sdt
                end
            end
        end
        
        for _ = 1, iters do
            self:solveConstraints(sdt)
        end
    end
end

-- Update bubble paths based on current particle positions
function updatePaths(self: SoftBodySim)
    for _, b in ipairs(self.bubbles) do
        local n = #b.particles
        if n > 0 then
            b.path:reset()

            -- Build a simple closed polygon (more robust than quad midpoint smoothing)
            local p0 = b.particles[1]
            b.path:moveTo(Vector.xy(p0.x, p0.y))
            for i = 2, n do
                local p = b.particles[i]
                b.path:lineTo(Vector.xy(p.x, p.y))
            end
            b.path:close()
        end
    end
end

function init(self: SoftBodySim, context: Context): boolean
    self.context = context
    self.isInitialized = false

    self._tweens = {}
    self._paramOverrides = {}

    self:initBubbles()

    local dur = math.floor(self.startupTweenFrames)
    if dur < 1 then dur = 1 end

    -- CHANGED: rename restAreaMultiplier -> pressure, and tween per-bubble pressures
    self:tweenParam("pressure", 1.0, self.pressure, dur)
    self:tweenParam("bubble1Pressure", 1.0, self.bubble1Pressure, dur)
    self:tweenParam("bubble2Pressure", 1.0, self.bubble2Pressure, dur)
    self:tweenParam("bubble3Pressure", 1.0, self.bubble3Pressure, dur)
    self:tweenParam("bubble4Pressure", 1.0, self.bubble4Pressure, dur)

    self:tweenParam("restLengthMultiplier", 1.0, self.restLengthMultiplier, dur)

    return true
end

function advance(self: SoftBodySim, dt: number): boolean
    self.frameCounter = self.frameCounter + 1
    self:updateTweens()

    local seg = clamp(math.floor(self.bubbleSegments), 3, 128)

    -- NEW: rebuild when any per-bubble size changes (fallback to bubbleRadius)
    local s1 = clamp((self.bubble1Size > 0) and self.bubble1Size or self.bubbleRadius, 1, 1000)
    local s2 = clamp((self.bubble2Size > 0) and self.bubble2Size or self.bubbleRadius, 1, 1000)
    local s3 = clamp((self.bubble3Size > 0) and self.bubble3Size or self.bubbleRadius, 1, 1000)
    local s4 = clamp((self.bubble4Size > 0) and self.bubble4Size or self.bubbleRadius, 1, 1000)

    if (seg ~= self._cachedSegments)
        or (s1 ~= self._cachedSize1) or (s2 ~= self._cachedSize2)
        or (s3 ~= self._cachedSize3) or (s4 ~= self._cachedSize4)
    then
        self:initBubbles()
    end

    -- If only invMass changes, patch particles without full rebuild
    local im = clamp(self.particleInvMass, 0, 1000000)
    if im ~= self._cachedInvMass then
        self._cachedInvMass = im
        for _, bub in ipairs(self.bubbles) do
            for _, p in ipairs(bub.particles) do
                p.invMass = im
            end
        end
    end

    local t = math.floor(self.throttle)
    if t < 1 then t = 1 end

    if (self.frameCounter % t) == 0 then
        self:simulate(dt)
        self:updatePaths()
    end
    return true
end

-- NEW: compute bubble center-of-mass (mass = 1/invMass). Falls back to simple average if needed.
local function bubbleCenterOfMass(b: Bubble): Vec2
    local sumMx = 0
    local sumMy = 0
    local sumM = 0

    local n = #b.particles
    for i = 1, n do
        local p = b.particles[i]
        if p.invMass > 0 then
            local m = 1.0 / p.invMass
            sumM = sumM + m
            sumMx = sumMx + p.x * m
            sumMy = sumMy + p.y * m
        end
    end

    if sumM > 0 then
        return { x = sumMx / sumM, y = sumMy / sumM }
    end

    -- fallback: average position (e.g. all invMass == 0)
    if n > 0 then
        local ax, ay = 0, 0
        for i = 1, n do
            ax = ax + b.particles[i].x
            ay = ay + b.particles[i].y
        end
        return { x = ax / n, y = ay / n }
    end

    return { x = 0, y = 0 }
end

-- NEW: build a tiny "circle" as a closed polygon (avoids relying on addOval APIs)
local function buildCirclePoly(path: Path, cx: number, cy: number, r: number, segments: number)
    local seg = math.floor(segments)
    if seg < 6 then seg = 6 end
    path:reset()
    for i = 0, seg - 1 do
        local a = (i / seg) * (2 * math.pi)
        local x = cx + math.cos(a) * r
        local y = cy + math.sin(a) * r
        if i == 0 then
            path:moveTo(Vector.xy(x, y))
        else
            path:lineTo(Vector.xy(x, y))
        end
    end
    path:close()
end

function draw(self: SoftBodySim, renderer: Renderer)
    if not self.isInitialized then return end

    -- Draw the box outline first
    renderer:drawPath(self.boxPath, self.boxPaint)

    -- Draw each bubble (fill + stroke so it's always visible)
    for _, b in ipairs(self.bubbles) do
        renderer:drawPath(b.path, b.paint)
        renderer:drawPath(b.path, b.strokePaint)

        local com = bubbleCenterOfMass(b)
        buildCirclePoly(b.comPath, com.x, com.y, 4.0, 12)
        renderer:drawPath(b.comPath, self.comPaint)
    end
end

return function(): Node<SoftBodySim>
    return {
        -- Default Properties (Inputs)
        gravity = 9.8,
        edgeCompliance = 0.0001,
        areaCompliance = 0.0001,
        damping = 1.0,
        substeps = 4,
        particleRadius = 15,
        throttle = 2,
        constraintIterations = 4,

        collisionDistanceFactor = 0.3,

        bubbleSegments = 60,
        bubbleRadius = 600.0, -- fallback/default
        particleInvMass = 1.0,

        -- RENAMED: was restAreaMultiplier
        pressure = 2.0,

        -- NEW: per-bubble pressure + size
        bubble1Pressure = 2.0,
        bubble2Pressure = 2.0,
        bubble3Pressure = 2.0,
        bubble4Pressure = 2.0,
        bubble1Size = 600.0,
        bubble2Size = 600.0,
        bubble3Size = 600.0,
        bubble4Size = 600.0,

        restLengthMultiplier = 0.9,

        startupTweenFrames = 60,

        -- State
        bubbles = {},
        width = 500,
        height = 500,
        isInitialized = false,
        context = late(),
        boxPath = Path.new(),
        boxPaint = Paint.with({
            style = 'stroke',
            thickness = 3,
            color = Color.rgb(255, 255, 255),
        }),
        frameCounter = 0,

        -- NEW: COM draw state
        -- FIX: remove shared comPath; keep shared paint only
        comPaint = Paint.with({
            style = 'fill',
            color = Color.rgb(255, 255, 255),
        }),

        _cachedSegments = 0,
        _cachedInvMass = 0,
        _cachedSize1 = 0,
        _cachedSize2 = 0,
        _cachedSize3 = 0,
        _cachedSize4 = 0,

        _cachedAreaMult = 0,
        _cachedLenMult = 0,

        _tweens = {},
        _paramOverrides = {},

        -- Methods
        initBubbles = initBubbles,
        solveConstraints = solveConstraints,
        simulate = simulate,
        updatePaths = updatePaths,

        tweenParam = tweenParam,
        updateTweens = updateTweens,
        getParam = getParam,

        init = init,
        advance = advance,
        draw = draw,
    }
end