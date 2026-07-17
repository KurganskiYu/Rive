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
	rotation: number,
	rotationSpeed: number,
	-- Cached reciprocal of mass (mass never changes during a particle's life).
	invMass: number,
	-- True if this particle was spawned by a burst (start or manual). Burst
	-- particles are a separate wave and do NOT count against the `count` cap.
	isBurst: boolean,
	-- Per-particle artboard instance so animations are independent.
	instance: Artboard?,
	path: Path?,
}
type ParticleSystemNode = {
	artboard: Input<Artboard>,
	-- Target number of live particles (also used to derive default emission rate).
	count: Input<number>,
	-- Optional explicit emission rate (particles per second). If <= 0, derived from count/life.
	emitRate: number,
	emit: Input<boolean>,
	intersectionSize: Input<number>,
	burst: Input<Trigger>,
	burstCount: Input<number>,
	-- When true, automatically fire a burst of `burstCount` particles at the start of the animation.
	startBurst: Input<boolean>,
	-- Duration (seconds) over which a burst (manual or start) is spread. 0 => instant.
	burstTime: Input<number>,
	emitWidth: Input<number>,
	emitHeight: Input<number>,
	speed: Input<number>,
	speedVar: Input<number>,
	radialSpeed: Input<boolean>,
	angle: Input<number>,
	angleVar: Input<number>,
	scale: Input<number>,
	scaleVar: Input<number>,
	mass: Input<number>,
	massVar: Input<number>,
	life: Input<number>,
	lifeVar: Input<number>,
	rotationMinSpeed: Input<number>,
	rotationMaxSpeed: Input<number>,
	randomRotationDirection: Input<boolean>,
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
	popDuration: Input<number>,
	trail: Input<boolean>,
	trailPaint: Paint,
	drawEmitter: Input<boolean>,
	emitterPaint: Paint,
	emitterPath: Path,
	
	drawLine: Input<boolean>,
	lineColor: Input<Color>,
	lineThickness: Input<number>,
	linePaint: Paint,
	linePath: Path,

	particles: { Particle },
	pool: { Particle },
	mat: Mat2D,
	time: number,
	-- Spawning accumulator for stable rate-based emission.
	emitCarry: number,
	-- Running count of live CONTINUOUS (non-burst) particles, maintained
	-- incrementally so we don't have to scan the list every frame.
	liveContinuous: number,
	-- Number of burst particles still waiting to be spawned (spread over burstTime).
	burstRemaining: number,
	-- Fractional accumulator for spreading burst emission across burstTime.
	burstCarry: number,
	-- Rate (particles/sec) at which the current burst is being emitted.
	burstRate: number,
}
-- Math shortcuts for performance
local mfloor = math.floor
local msin = math.sin
local mcos = math.cos
local mrad = math.rad
local mrandom = math.random
local mmax = math.max
local twopi = 6.28318530718
-- Noise functions: Perlin noise 3D (stationary turbulence evolution via time as Z).
--
-- Performance: the gradient hash is table-driven instead of computed with
-- math.sin per corner. We build a 256-entry permutation table once (seeded so
-- results are deterministic across runs) and duplicate it to 512 to avoid
-- index wrapping in the hot path. This removes ~8 sin() calls per noise sample
-- while keeping the classic Perlin 12-edge gradient logic byte-for-byte, so the
-- resulting field has the same statistical character (and visual look) as
-- before, just far cheaper.
local perm = buffer.create(512)
do
	-- Deterministic Fisher-Yates shuffle of 0..255.
	local p = {}
	for i = 0, 255 do
		p[i] = i
	end
	-- Fixed seed so the noise pattern is stable between plays/exports.
	local seed = 1
	local function nextRand(): number
		-- Simple LCG (deterministic, independent of math.random state).
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for i = 255, 1, -1 do
		local j = mfloor(nextRand() * (i + 1))
		p[i], p[j] = p[j], p[i]
	end
	for i = 0, 511 do
		buffer.writeu8(perm, i, p[i % 256])
	end
end

-- Classic Perlin gradient: uses the low 4 bits of the hash to pick one of the
-- 12 edge directions. Identical logic to the original, just fed by a table hash.
local function grad3D(hash: number, dx: number, dy: number, dz: number): number
	local h = hash % 16
	local u = (h < 8) and dx or dy
	local v = (h < 4) and dy or ((h == 12 or h == 14) and dx or dz)
	local res = ((h % 2) == 0 and u or -u) + ((mfloor(h / 2) % 2) == 0 and v or -v)
	return res
end

local function perlin3D(x: number, y: number, z: number): number
	local fx0 = mfloor(x)
	local fy0 = mfloor(y)
	local fz0 = mfloor(z)
	
	local dx0 = x - fx0
	local dy0 = y - fy0
	local dz0 = z - fz0
	local dx1 = dx0 - 1
	local dy1 = dy0 - 1
	local dz1 = dz0 - 1
	
	-- Fade curves (unchanged)
	local sx = dx0 * dx0 * dx0 * (dx0 * (dx0 * 6 - 15) + 10)
	local sy = dy0 * dy0 * dy0 * (dy0 * (dy0 * 6 - 15) + 10)
	local sz = dz0 * dz0 * dz0 * (dz0 * (dz0 * 6 - 15) + 10)
	
	-- Lattice indices wrapped into the 0..255 permutation domain.
	local X = fx0 % 256
	local Y = fy0 % 256
	local Z = fz0 % 256
	if X < 0 then X = X + 256 end
	if Y < 0 then Y = Y + 256 end
	if Z < 0 then Z = Z + 256 end
	
	-- Standard Perlin permutation hashing of the 8 cube corners.
	local A = buffer.readu8(perm, X) + Y
	local B = buffer.readu8(perm, X + 1) + Y
	local AA = buffer.readu8(perm, A) + Z
	local AB = buffer.readu8(perm, A + 1) + Z
	local BA = buffer.readu8(perm, B) + Z
	local BB = buffer.readu8(perm, B + 1) + Z
	
	-- Trilinear interpolation of 8 corners
	local n000 = grad3D(buffer.readu8(perm, AA), dx0, dy0, dz0)
	local n100 = grad3D(buffer.readu8(perm, BA), dx1, dy0, dz0)
	local n010 = grad3D(buffer.readu8(perm, AB), dx0, dy1, dz0)
	local n110 = grad3D(buffer.readu8(perm, BB), dx1, dy1, dz0)
	
	local n001 = grad3D(buffer.readu8(perm, AA + 1), dx0, dy0, dz1)
	local n101 = grad3D(buffer.readu8(perm, BA + 1), dx1, dy0, dz1)
	local n011 = grad3D(buffer.readu8(perm, AB + 1), dx0, dy1, dz1)
	local n111 = grad3D(buffer.readu8(perm, BB + 1), dx1, dy1, dz1)
	
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
		rotation = 0,
		rotationSpeed = 0,
		invMass = 1,
		isBurst = false,
		instance = nil,
		path = nil,
	}
end

local function spawn(sys: ParticleSystemNode, p: Particle)
	-- Default to a continuous-wave particle. Burst spawns set isBurst=true after.
	p.isBurst = false
	p.life = 0
	p.maxLife = mmax(0.1, randomRange(sys.life, sys.lifeVar))
	p.scale = mmax(0, randomRange(sys.scale, sys.scaleVar))
	p.mass = mmax(0.1, randomRange(sys.mass, sys.massVar))
	p.invMass = 1 / p.mass
	
	-- Ensure particles spawn strictly within the emission area (0 to width/height)
	local isectSizeSq = sys.intersectionSize * sys.intersectionSize
	if isectSizeSq > 0 then
		local attempts = 0
		local maxAttempts = 25 -- Increased slightly since it's now highly optimized
		local bestX = 0
		local bestY = 0
		local maxMinDistSq = -1
		local particles = sys.particles
		local count = #particles
		
		while attempts < maxAttempts do
			local px = mrandom() * sys.emitWidth
			local py = mrandom() * sys.emitHeight
			local minDistSq = math.huge
			
			for i = 1, count do
				local other = particles[i]
				local dx = px - other.x
				local dy = py - other.y
				local distSq = dx * dx + dy * dy
				if distSq < minDistSq then
					minDistSq = distSq
				end
				-- Optimization: reject candidate early if it's already worse than our best candidate
				if minDistSq <= maxMinDistSq then
					break
				end
			end
			
			if minDistSq > maxMinDistSq then
				maxMinDistSq = minDistSq
				bestX = px
				bestY = py
				-- Early success: fully satisfies intersection size
				if maxMinDistSq >= isectSizeSq then
					break
				end
			end
			attempts = attempts + 1
		end
		p.x = bestX
		p.y = bestY
	else
		p.x = mrandom() * sys.emitWidth
		p.y = mrandom() * sys.emitHeight
	end
	
	local s = randomRange(sys.speed, sys.speedVar)
	
	if sys.radialSpeed then
		local cx = sys.emitWidth * 0.5
		local cy = sys.emitHeight * 0.5
		local dx = p.x - cx
		local dy = p.y - cy
		local dist = math.sqrt(dx * dx + dy * dy)
		if dist > 0.0001 then
			p.vx = (dx / dist) * s
			p.vy = (dy / dist) * s
		else
			p.vx = 0
			p.vy = 0
		end
	else
		local a = mrad(randomRange(sys.angle, sys.angleVar))
		p.vx = mcos(a) * s
		p.vy = msin(a) * s
	end

	p.gravity = randomRange(sys.gravity, sys.gravityVar)
	p.windX = randomRange(sys.windX, sys.windXVar)
	p.windY = randomRange(sys.windY, sys.windYVar)
	p.noiseStrX = sys.noiseStrengthX
	p.noiseStrY = sys.noiseStrengthY
	p.noiseFreq = toNoiseFreq(randomRange(sys.noiseScale, sys.noiseScaleVar))
	
	p.rotation = 0
	local rSpeed = sys.rotationMinSpeed
	if sys.rotationMaxSpeed > sys.rotationMinSpeed then
		rSpeed = sys.rotationMinSpeed + mrandom() * (sys.rotationMaxSpeed - sys.rotationMinSpeed)
	end
	
	local dir = 1
	if sys.randomRotationDirection then
		dir = (mrandom() < 0.5) and 1 or -1
	end
	p.rotationSpeed = mrad(rSpeed * dir)
	
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

-- Queue a burst of `n` particles to be emitted, spread across `burstTime`
-- seconds (or instantly if burstTime <= 0). Burst particles are a separate
-- wave that ignores the `count` cap, and they live their full lifetime.
local function queueBurst(self: ParticleSystemNode, n: number)
	if n <= 0 then
		return
	end
	self.burstRemaining = self.burstRemaining + n
	local bt = self.burstTime
	if bt > 0 then
		-- Total particles pending (in case a burst is already in progress).
		self.burstRate = self.burstRemaining / bt
	else
		-- Instant burst: emit everything on the next advance.
		self.burstRate = 0
	end
end

local function burst(self: ParticleSystemNode)
	-- Manual burst trigger from the state machine / listener.
	queueBurst(self, mfloor(self.burstCount))
end

local function init(self: ParticleSystemNode, context: Context): boolean
	self.time = 0
	self.emitCarry = 0 
	self.liveContinuous = 0
	self.burstRemaining = 0
	self.burstCarry = 0
	self.burstRate = 0
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
	self.linePaint = Paint.with({
		style = "stroke",
		color = self.lineColor,
		thickness = self.lineThickness,
	})
	self.linePath = Path.new()
	self.emitterPath = Path.new()
	self.particles = {}
	self.pool = {}
	self.mat = Mat2D.identity()
	for _ = 1, self.count do
		table.insert(self.pool, createRawParticle())
	end
	
	-- Pre-seed the continuous wave at steady state so the `count` particles are
	-- already alive (with randomized lives) instead of being born as a pack.
	if self.emit then
		for _ = 1, self.count do
			local p = table.remove(self.pool)
			if p then
				spawn(self, p)
				p.life = mrandom() * p.maxLife
				table.insert(self.particles, p)
				self.liveContinuous = self.liveContinuous + 1
			end
		end
	end
	
	-- Automatic Start Burst: fire a full burst of `burstCount` particles at the
	-- start of the animation, spread across `burstTime`. These are a separate
	-- wave that does NOT count against `count`, so they live their full life.
	if self.startBurst then
		queueBurst(self, mfloor(self.burstCount))
	end
	
	return true
end
local function advance(self: ParticleSystemNode, seconds: number): boolean
	-- Fixed-timestep safety: clamp the delta so a frame spike (tab refocus,
	-- hitch, breakpoint) can't make particles tunnel through the emit area,
	-- over-emit in a single frame, or blow up friction. 0.05s == a 20fps floor.
	if seconds > 0.05 then
		seconds = 0.05
	end
	
	self.time = self.time + seconds
	-- Wrap noise time to avoid floating point precision issues after long duration.
	-- 10000 is arbitrary but large enough to not be noticeable, and small enough to keep precision.
	local noiseTime = self.time % 10000
	
	local particles = self.particles
	local pool = self.pool

	-- Process Burst emission (start burst and/or manual bursts).
	-- Burst particles are a SEPARATE wave: they ignore the `count` cap and live
	-- their full lifetime (no life scrambling). When burstTime > 0 the burst is
	-- spread out over that duration; otherwise it's emitted instantly.
	if self.burstRemaining > 0 then
		local toSpawn: number
		if self.burstRate > 0 then
			self.burstCarry = self.burstCarry + self.burstRate * seconds
			toSpawn = mfloor(self.burstCarry)
			if toSpawn > self.burstRemaining then
				toSpawn = self.burstRemaining
			end
			self.burstCarry = self.burstCarry - toSpawn
		else
			-- Instant burst.
			toSpawn = self.burstRemaining
		end
		
		for _ = 1, toSpawn do
			-- Explicitly type 'p' as Particle to satisfy strict type checker
			local p: Particle = table.remove(pool) or createRawParticle()
			spawn(self, p)
			p.isBurst = true
			table.insert(particles, p)
		end
		self.burstRemaining = self.burstRemaining - toSpawn
		if self.burstRemaining <= 0 then
			self.burstCarry = 0
			self.burstRate = 0
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
	-- Don't exceed target `count` live CONTINUOUS particles. Burst particles are
	-- a separate wave and must not consume the continuous emission budget. We
	-- track the continuous count incrementally instead of scanning the list.
	local capacity = self.count - self.liveContinuous
	if self.emit and capacity > 0 and #pool > 0 and rate > 0 then
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
				self.liveContinuous = self.liveContinuous + 1
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
			-- Particle died. Return the struct to the pool. Use swap-and-pop
			-- (O(1)) instead of table.remove's O(n) shift: move the last element
			-- into slot i and drop the tail.
			p.instance = nil
			if p.path then p.path:reset() end
			if not p.isBurst then
				self.liveContinuous = self.liveContinuous - 1
			end
			table.insert(pool, p)
			particles[i] = particles[count]
			particles[count] = nil
			count = count - 1
			-- Do NOT advance i: the swapped-in element still needs processing.
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
			
			local invMass = p.invMass
			
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
			
			p.rotation = (p.rotation + p.rotationSpeed * seconds) % twopi

			if self.trail and p.path then
				p.path:lineTo(Vector.xy(p.x, p.y))
			end

			if p.instance and p.instance.data and p.instance.data.pop then
				local shouldPop = false
				
				-- 1. Pop before death (based on configured popDuration), providing it lived at least 30% of its lifetime
				if (p.maxLife - p.life) <= self.popDuration and p.life >= (p.maxLife * 0.3) then
					shouldPop = true
				end
				
				-- 2. Pop if completely outside emission area (if configured)
				if not shouldPop and self.popOutside then
					if p.x < 0 or p.x > self.emitWidth or p.y < 0 or p.y > self.emitHeight then
						shouldPop = true
					end
				end
				
				-- Explicitly assign shouldPop so it can switch false/true properly every frame
				p.instance.data.pop.value = shouldPop
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

	if self.drawLine and #particles > 1 then
		local linePath = self.linePath
		linePath:reset()
		local p = particles[1]
		linePath:moveTo(Vector.xy(p.x, p.y))
		for i = 2, #particles do
			p = particles[i]
			linePath:lineTo(Vector.xy(p.x, p.y))
		end
		
		-- Update paint dynamically in case inputs animated
		self.linePaint.color = self.lineColor
		self.linePaint.thickness = self.lineThickness
		renderer:drawPath(linePath, self.linePaint)
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
			local finalScale = p.scale
			local cosRot = mcos(p.rotation)
			local sinRot = msin(p.rotation)
			mat.xx = finalScale * cosRot
			mat.xy = finalScale * sinRot 
			mat.yx = -finalScale * sinRot
			mat.yy = finalScale * cosRot
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
		emit = true,
		intersectionSize = 0,
		burst = burst,
		burstCount = 200,
		startBurst = false,
		burstTime = 1.0,
		emitWidth = 0,
		emitHeight = 0,
		speed = 10,
		speedVar = 0,
		radialSpeed = false,
		angle = 0,
		angleVar = 360,
		scale = 0.7,
		scaleVar = 0.5,
		mass = 1,
		massVar = 0,
		life = 5,
		lifeVar = 0,
		rotationMinSpeed = 0.0,
		rotationMaxSpeed = 0.0,
		randomRotationDirection = false,
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
		popDuration = 0.5,
		trail = false,
		trailPaint = late(),
		drawEmitter = false,
		emitterPaint = late(),
		emitterPath = late(),
		drawLine = false,
		lineColor = Color.rgba(255, 255, 255, 170),
		lineThickness = 1.0,
		linePaint = late(),
		linePath = late(),
		artboard = late(),
		particles = {},
		pool = {},
		mat = late(),
		time = 0,
		emitCarry = 0,
		liveContinuous = 0,
		burstRemaining = 0,
		burstCarry = 0,
		burstRate = 0,
		init = init,
		advance = advance,
		draw = draw,
	}
end

