-- ParticleSystem: Noise-based particle system
-- Type definitions
type Particle = {
	x: number,
	y: number,
	vx: number,
	vy: number,
	scale: number,
	life: number,
	maxLife: number,
	gravity: number,
	windX: number,
	windY: number,
	noiseStr: number,
	noiseFreq: number,
	-- Per-particle artboard instance so animations are independent.
	instance: Artboard?,
}
type ParticleSystemNode = {
	-- Target number of live particles (also used to derive default emission rate).
	count: Input<number>,
	-- Optional explicit emission rate (particles per second). If <= 0, derived from count/life.
	emitRate: number,
	emitWidth: Input<number>,
	emitHeight: Input<number>,
	speed: Input<number>,
	speedVar: Input<number>,
	angle: Input<number>,
	angleVar: Input<number>,
	scale: Input<number>,
	scaleVar: Input<number>,
	life: Input<number>,
	lifeVar: Input<number>,
	noiseStrength: Input<number>,
	noiseScale: Input<number>,
	noiseScaleVar: number,
	noiseTimeScale: Input<number>,
	windX: number,
	windXVar: number,
	windY: number,
	windYVar: number,
	gravity: Input<number>,
	gravityVar: number,
	friction: Input<number>,
	artboard: Input<Artboard>,
	-- Template artboard instance used only as a source for per-particle instancing.
	template: Artboard,
	particles: { Particle },
	pool: { Particle },
	mat: Mat2D,
	time: number,
	-- Spawning accumulator for stable rate-based emission.
	emitCarry: number,
}
-- Math shortcuts for performance
local mfloor = math.floor
local msin = math.sin
local mcos = math.cos
local mrad = math.rad
local mrandom = math.random
local mmax = math.max
local twopi = 6.28318530718
-- Noise functions: Perlin noise and fractal Brownian motion (FBM)
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
	for _ = 1, octaves do
		total = total + perlin2D(x * freq, y * freq) * amplitude
		maxValue = maxValue + amplitude
		amplitude = amplitude * rough
		freq = freq * 2
	end
	-- Normalize to [-1, 1] range so scale doesn't affect strength
	return total / maxValue
end
-- Helper functions
local function randomRange(base: number, range: number): number
	if range == 0 then
		return base
	end
	return base + (mrandom() - 0.5) * range
end
-- Map the user-facing noise scale (size) to internal frequency (1/size).
local function toNoiseFreq(userScale: number): number
	local s = mmax(0.001, userScale)
	return 1 / s
end
local function spawn(sys: ParticleSystemNode, p: Particle)
	p.life = 0
	p.maxLife = mmax(0.1, randomRange(sys.life, sys.lifeVar))
	p.scale = mmax(0, randomRange(sys.scale, sys.scaleVar))
	local a = mrad(randomRange(sys.angle, sys.angleVar))
	local s = randomRange(sys.speed, sys.speedVar)
	p.vx = mcos(a) * s
	p.vy = msin(a) * s
	p.x = randomRange(0, sys.emitWidth)
	p.y = randomRange(0, sys.emitHeight)
	p.gravity = randomRange(sys.gravity, sys.gravityVar)
	p.windX = randomRange(sys.windX, sys.windXVar)
	p.windY = randomRange(sys.windY, sys.windYVar)
	p.noiseStr = sys.noiseStrength
	p.noiseFreq = toNoiseFreq(randomRange(sys.noiseScale, sys.noiseScaleVar))
	-- Each particle gets a fresh artboard instance so animations start from the beginning.
	p.instance = sys.artboard:instance()
end
local function init(self: ParticleSystemNode, context: Context): boolean
	self.time = 0
	self.emitCarry = 0
	self.particles = {}
	self.pool = {}
	-- Template is kept only to ensure artboard input is valid early.
	self.template = self.artboard:instance()
	self.mat = Mat2D.identity()
	for _ = 1, self.count do
		table.insert(self.pool, {
			x = 0,
			y = 0,
			vx = 0,
			vy = 0,
			scale = 1,
			life = 0,
			maxLife = 1,
			gravity = 0,
			windX = 0,
			windY = 0,
			noiseStr = 0,
			noiseFreq = toNoiseFreq(0.01),
			instance = nil,
		})
	end
	return true
end
local function advance(self: ParticleSystemNode, seconds: number): boolean
	self.time = self.time + seconds
	local particles = self.particles
	local pool = self.pool
	-- Stable emission:
	-- Emit at a constant rate, carrying fractional particles between frames.
	-- If emitRate <= 0, derive from count/avgLife (roughly maintains `count` live particles).
	local avgLife = mmax(0.1, self.life)
	local rate = self.emitRate
	if rate <= 0 then
		rate = self.count / avgLife
	end
	-- Don't exceed target `count` live particles.
	local capacity = self.count - #particles
	if capacity > 0 and #pool > 0 and rate > 0 then
		self.emitCarry = self.emitCarry + rate * seconds
		local toSpawn = mfloor(self.emitCarry)
		if toSpawn > capacity then
			toSpawn = capacity
		end
		if toSpawn > #pool then
			toSpawn = #pool
		end
		if toSpawn > 0 then
			self.emitCarry = self.emitCarry - toSpawn
			for _ = 1, toSpawn do
				local p = table.remove(pool)
				if not p then
					break
				end
				spawn(self, p)
				table.insert(particles, p)
			end
		end
	end
	-- Update existing particles
	local i = 1
	local count = #particles
	while i <= count do
		local p = particles[i]
		p.life = p.life + seconds
		if p.life >= p.maxLife then
			-- Particle died, return to pool
			p.instance = nil
			table.insert(pool, p)
			if i < count then
				local last = particles[count]
				if last then
					particles[i] = last
				end
			end
			particles[count] = nil
			count = count - 1
		else
			-- Apply noise-based forces (noise directly influences velocity for chaotic movement)
			local timeOffset = self.time * self.noiseTimeScale
			local nx = fbm(p.x * p.noiseFreq + timeOffset, p.y * p.noiseFreq + timeOffset, 0.5, 2)
			local ny = fbm(p.x * p.noiseFreq + 100 + timeOffset, p.y * p.noiseFreq + 100 + timeOffset, 0.5, 2)
			
			 -- Normalize noise strength by frequency so scale doesn't affect force magnitude
			-- Higher frequency (smaller scale) = tighter patterns but same force
			-- Lower frequency (larger scale) = broader patterns but same force
			local normalizedStr = p.noiseStr * p.noiseFreq
			
			-- Noise and wind directly set velocity component (chaotic), gravity accumulates
			p.vy = p.vy + p.gravity * seconds
			
			-- Add wind and noise as forces (not accumulating velocity)
			local windNoiseX = (p.windX + nx * normalizedStr) * seconds
			local windNoiseY = (p.windY + ny * normalizedStr) * seconds
			
			p.vx = p.vx + windNoiseX
			p.vy = p.vy + windNoiseY
			
			-- Apply air friction (damping)
			local friction = 1 - mmax(0, self.friction) * seconds
			if friction < 0 then friction = 0 end
			p.vx = p.vx * friction
			p.vy = p.vy * friction
			
			p.x = p.x + p.vx * seconds
			p.y = p.y + p.vy * seconds
			if p.instance then
				p.instance:advance(seconds)
			end
			i = i + 1
		end
	end
	return true
end
local function draw(self: ParticleSystemNode, renderer: Renderer)
	local particles = self.particles
	local mat = self.mat
	for i = 1, #particles do
		local p = particles[i]
		local instance = p.instance
		if not instance then
			-- Shouldn't happen, but keep safe if pool was externally mutated.
			instance = self.artboard:instance()
			p.instance = instance
		end
		if instance then
			renderer:save()
			mat.xx = p.scale
			mat.xy = 0
			mat.yx = 0
			mat.yy = p.scale
			mat.tx = p.x
			mat.ty = p.y
			renderer:transform(mat)
			instance:draw(renderer)
			renderer:restore()
		end
	end
end
-- Return the node factory function
return function(): Node<ParticleSystemNode>
	return {
		count = 100,
		emitRate = 0, -- 0 => auto (count / life)
		emitWidth = 0,
		emitHeight = 0,
		speed = 10,
		speedVar = 0,
		angle = -90,
		angleVar = 360,
		scale = 0.3,
		scaleVar = 0.5,
		life = 2,
		lifeVar = 1,
		noiseStrength = 2000,
		noiseScale = 5.0,
		noiseScaleVar = 0,
		noiseTimeScale = 10.5,
		windX = 0,
		windXVar = 0,
		windY = 0,
		windYVar = 0,
		gravity = 0,
		gravityVar = 0,
		friction = 0.5,
		artboard = late(),
		template = late(),
		particles = {},
		pool = {},
		mat = late(),
		time = 0,
		emitCarry = 0,
		init = init,
		advance = advance,
		draw = draw,
	}
end

