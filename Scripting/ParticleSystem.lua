-- ParticleSystem: Noise-based particle system
-- Type definitions
type ParticleVM = {
	pop: Property<boolean>,
}
type Particle = {
	x: number,
	y: number,
	vx: number,
	vy: number,
	scale: number,
	mass: number,
	life: number,
	maxLife: number,
	gravity: number,
	windX: number,
	windY: number,
	noiseStrX: number,
	noiseStrY: number,
	noiseFreq: number,
	-- Per-particle artboard instance so animations are independent.
	instance: Artboard?,
	path: Path?,
}
type ParticleSystemNode = {
	-- Target number of live particles (also used to derive default emission rate).
	count: Input<number>,
	-- Optional explicit emission rate (particles per second). If <= 0, derived from count/life.
	emitRate: number,
	burst: Input<Trigger>,
	burstCount: Input<number>,
	emitWidth: Input<number>,
	emitHeight: Input<number>,
	speed: Input<number>,
	speedVar: Input<number>,
	angle: Input<number>,
	angleVar: Input<number>,
	scale: Input<number>,
	scaleVar: Input<number>,
	mass: Input<number>,
	massVar: Input<number>,
	life: Input<number>,
	lifeVar: Input<number>,
	noiseStrengthX: Input<number>,
	noiseStrengthY: Input<number>,
	noiseOctaves: Input<number>,
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
	popOutside: Input<boolean>,
	trail: Input<boolean>,
	trailPaint: Paint,
	drawEmitter: Input<boolean>,
	emitterPaint: Paint,
	emitterPath: Path,
	artboard: Input<Artboard>,
	-- Template artboard instance used only as a source for per-particle instancing.
	template: Artboard,
	particles: { Particle },
	pool: { Particle },
	mat: Mat2D,
	time: number,
	-- Spawning accumulator for stable rate-based emission.
	emitCarry: number,
	-- Burst request accumulator
	burstReq: number,
}
-- Math shortcuts for performance
local mfloor = math.floor
local msin = math.sin
local mcos = math.cos
local mrad = math.rad
local mrandom = math.random
local mmax = math.max
local twopi = 6.28318530718
-- Noise functions: Perlin noise 3D (Replacing 2D for stationary turbulence evolution)
local function grad3D(ix: number, iy: number, iz: number, dx: number, dy: number, dz: number): number
	-- Simple hash using sines to avoid large tables
	local sinVal = msin(ix * 12.9898 + iy * 78.233 + iz * 37.719) * 43758.5453
	local h = mfloor((sinVal - mfloor(sinVal)) * 16)
	
	-- Gradient direction based on hash (simplified Perlin 12-edge logic)
	local u = (h < 8) and dx or dy
	local v = (h < 4) and dy or ((h == 12 or h == 14) and dx or dz)
	local res = ((h % 2) == 0 and u or -u) + ((mfloor(h/2) % 2) == 0 and v or -v)
	return res
end

local function perlin3D(x: number, y: number, z: number): number
	local x0 = mfloor(x)
	local y0 = mfloor(y)
	local z0 = mfloor(z)
	
	local dx0 = x - x0
	local dy0 = y - y0
	local dz0 = z - z0
	local dx1 = dx0 - 1
	local dy1 = dy0 - 1
	local dz1 = dz0 - 1
	
	-- Fade curves
	local sx = dx0 * dx0 * dx0 * (dx0 * (dx0 * 6 - 15) + 10)
	local sy = dy0 * dy0 * dy0 * (dy0 * (dy0 * 6 - 15) + 10)
	local sz = dz0 * dz0 * dz0 * (dz0 * (dz0 * 6 - 15) + 10)
	
	-- Trilinear interpolation of 8 corners
	local n000 = grad3D(x0, y0, z0, dx0, dy0, dz0)
	local n100 = grad3D(x0+1, y0, z0, dx1, dy0, dz0)
	local n010 = grad3D(x0, y0+1, z0, dx0, dy1, dz0)
	local n110 = grad3D(x0+1, y0+1, z0, dx1, dy1, dz0)
	
	local n001 = grad3D(x0, y0, z0+1, dx0, dy0, dz1)
	local n101 = grad3D(x0+1, y0, z0+1, dx1, dy0, dz1)
	local n011 = grad3D(x0, y0+1, z0+1, dx0, dy1, dz1)
	local n111 = grad3D(x0+1, y0+1, z0+1, dx1, dy1, dz1)
	
	local ix0 = n000 + sx * (n100 - n000)
	local ix1 = n010 + sx * (n110 - n010)
	local ixy0 = ix0 + sy * (ix1 - ix0)
	
	local ix2 = n001 + sx * (n101 - n001)
	local ix3 = n011 + sx * (n111 - n011)
	local ixy1 = ix2 + sy * (ix3 - ix2)
	
	return ixy0 + sz * (ixy1 - ixy0)
end

local function fbm(x: number, y: number, z: number, rough: number, octaves: number): number
	local total = 0
	local amplitude = 1
	local maxValue = 0
	local freq = 0.5
	for _ = 1, octaves do
		total = total + perlin3D(x * freq, y * freq, z * freq) * amplitude
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

local function createRawParticle(): Particle
	return {
		x = 0,
		y = 0,
		vx = 0,
		vy = 0,
		scale = 1,
		mass = 1,
		life = 0,
		maxLife = 1,
		gravity = 0,
		windX = 0,
		windY = 0,
		noiseStrX = 0,
		noiseStrY = 0,
		noiseFreq = toNoiseFreq(0.01),
		instance = nil,
		path = nil,
	}
end

local function spawn(sys: ParticleSystemNode, p: Particle)
	p.life = 0
	p.maxLife = mmax(0.1, randomRange(sys.life, sys.lifeVar))
	p.scale = mmax(0, randomRange(sys.scale, sys.scaleVar))
	p.mass = mmax(0.1, randomRange(sys.mass, sys.massVar))
	local a = mrad(randomRange(sys.angle, sys.angleVar))
	local s = randomRange(sys.speed, sys.speedVar)
	p.vx = mcos(a) * s
	p.vy = msin(a) * s
	-- Ensure particles spawn strictly within the emission area (0 to width/height)
	p.x = mrandom() * sys.emitWidth
	p.y = mrandom() * sys.emitHeight
	p.gravity = randomRange(sys.gravity, sys.gravityVar)
	p.windX = randomRange(sys.windX, sys.windXVar)
	p.windY = randomRange(sys.windY, sys.windYVar)
	p.noiseStrX = sys.noiseStrengthX
	p.noiseStrY = sys.noiseStrengthY
	p.noiseFreq = toNoiseFreq(randomRange(sys.noiseScale, sys.noiseScaleVar))
	
	if sys.trail then
		if not p.path then
			p.path = Path.new()
		end
		-- Check p.path again in case allocation failed
		if p.path then
			p.path:reset()
			p.path:moveTo(Vector.xy(p.x, p.y))
		end
	elseif p.path then
		p.path:reset()
	end

	-- Each particle gets a fresh artboard instance so animations start from the beginning.
	p.instance = sys.artboard:instance()
	-- Reset pop state to ensure it starts valid on first frame
	if sys.popOutside and p.instance and p.instance.data and p.instance.data.pop then
		p.instance.data.pop.value = false
	end
end

local function burst(self: ParticleSystemNode)
	-- Accumulate burst request to be processed in advance()
	self.burstReq = self.burstReq + mfloor(self.burstCount)
end

local function init(self: ParticleSystemNode, context: Context): boolean
	self.time = 0
	self.emitCarry = 0 
	self.burstReq = 0
	self.trailPaint = Paint.with({
		style = "stroke",
		color = 0xAAFFFFFF,
		thickness = 0.3,
	})
	self.emitterPaint = Paint.with({
		style = "stroke",
		color = 0xFF00FF00,
		thickness = 1,
	})
	self.emitterPath = Path.new()
	self.particles = {}
	self.pool = {}
	-- Template is kept only to ensure artboard input is valid early.
	self.template = self.artboard:instance()
	self.mat = Mat2D.identity()
	for _ = 1, self.count do
		table.insert(self.pool, createRawParticle())
	end
	return true
end
local function advance(self: ParticleSystemNode, seconds: number): boolean
	self.time = self.time + seconds
	-- Wrap noise time to avoid floating point precision issues after long duration.
	-- 10000 is arbitrary but large enough to not be noticeable, and small enough to keep precision.
	local noiseTime = self.time % 10000
	
	local particles = self.particles
	local pool = self.pool

	-- Process Burst Requests
	-- This allows exceeding the 'count' limit temporarily
	if self.burstReq > 0 then
		local bCount = self.burstReq
		self.burstReq = 0
		
		for _ = 1, bCount do
			-- Explicitly type 'p' as Particle to satisfy strict type checker
			local p: Particle = table.remove(pool) or createRawParticle()
			spawn(self, p)
			table.insert(particles, p)
		end
	end

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
	local octaves = mfloor(mmax(1, self.noiseOctaves))
	while i <= count do
		local p = particles[i]
		p.life = p.life + seconds
		if p.life >= p.maxLife then
			-- Particle died, return to pool
			p.instance = nil
			if p.path then p.path:reset() end
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
			-- Use Time as Z dimension to animate noise "bubbling" without directional sliding
			local timeZ = noiseTime * self.noiseTimeScale
			local nx = fbm(p.x * p.noiseFreq, p.y * p.noiseFreq, timeZ, 0.5, octaves)
			local ny = fbm(p.x * p.noiseFreq + 100, p.y * p.noiseFreq + 100, timeZ, 0.5, octaves)
			
			-- Optionally normalize the noise vector direction so diagonal noise isn't stronger
			-- This ensures the maximum "kick" from noise is consistent in all directions
			local len = math.sqrt(nx * nx + ny * ny)
			if len > 1 then
				nx = nx / len
				ny = ny / len
			end

			-- Gravity acts as a force (accumulates in velocity)
			p.vy = p.vy + p.gravity * seconds
			
			local invMass = 1 / p.mass
			
			-- Apply air friction (damping) to physics velocity
			-- Heavier particles have more inertia, so friction affects them less (a = F/m)
			local friction = 1 - mmax(0, self.friction * invMass) * seconds
			if friction < 0 then friction = 0 end
			p.vx = p.vx * friction
			p.vy = p.vy * friction
			
			-- Apply Noise and Wind as Velocity modifiers (Turbulence) rather than Force
			-- Mass acts as resistance to the wind/noise field.
			local turbX = (p.windX + nx * p.noiseStrX) * invMass
			local turbY = (p.windY + ny * p.noiseStrY) * invMass
			
			-- Integrate position: Internal Momentum + Environmental Turbulence
			p.x = p.x + (p.vx + turbX) * seconds
			p.y = p.y + (p.vy + turbY) * seconds

			if self.trail and p.path then
				p.path:lineTo(Vector.xy(p.x, p.y))
			end

			if self.popOutside and p.instance and p.instance.data and p.instance.data.pop then
				local isOutside = p.x < 0 or p.x > self.emitWidth or p.y < 0 or p.y > self.emitHeight
				p.instance.data.pop.value = isOutside
			end

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

	if self.drawEmitter then
		local ep = self.emitterPath
		ep:reset()
		ep:moveTo(Vector.xy(0, 0))
		ep:lineTo(Vector.xy(self.emitWidth, 0))
		ep:lineTo(Vector.xy(self.emitWidth, self.emitHeight))
		ep:lineTo(Vector.xy(0, self.emitHeight))
		ep:close()
		renderer:drawPath(ep, self.emitterPaint)
	end

	if self.trail then
		for i = 1, #particles do
			local p = particles[i]
			if p.path then
				renderer:drawPath(p.path, self.trailPaint)
			end
		end
	end

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
		count = 30,
		emitRate = 0, -- 0 => auto (count / life)
		burst = burst,
		burstCount = 200,
		emitWidth = 0,
		emitHeight = 0,
		speed = 10,
		speedVar = 0,
		angle = 0,
		angleVar = 360,
		scale = 0.7,
		scaleVar = 0.5,
		mass = 1,
		massVar = 0,
		life = 5,
		lifeVar = 0,
		noiseStrengthX = 20,
		noiseStrengthY = 20,
		noiseOctaves = 0,
		noiseScale = 30.0,
		noiseScaleVar = 0,
		noiseTimeScale = 1.0,
		windX = 0,
		windXVar = 0,
		windY = 0,
		windYVar = 0,
		gravity = 0,
		gravityVar = 0,
		friction = 0.0,
		popOutside = false,
		trail = false,
		trailPaint = late(),
		drawEmitter = false,
		emitterPaint = late(),
		emitterPath = late(),
		artboard = late(),
		template = late(),
		particles = {},
		pool = {},
		mat = late(),
		time = 0,
		emitCarry = 0,
		burstReq = 0,
		init = init,
		advance = advance,
		draw = draw,
	}
end

