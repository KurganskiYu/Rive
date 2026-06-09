-- ParticleSystem: Optimized Simple Ring Particle System
-- Type definitions
type Particle = {
	x: number,
	y: number,
	scale: number,
	life: number,
	maxLife: number,
	instance: Artboard?,
	born: boolean,
	delay: number,
}

type ParticleSystemNode = {
	artboard: Input<Artboard>,
	count: Input<number>,
	insideRadius: Input<number>,
	outsideRadius: Input<number>,
	life: Input<number>,
	lifeVar: Input<number>,
	scale: Input<number>,
	scaleVar: Input<number>,
	drawEmitter: Input<boolean>,
	
	emitterPaint: Paint,
	emitterPath: Path,
	particles: { Particle },
	mat: Mat2D,
}

-- Math shortcuts for performance
local mmax = math.max
local mfloor = math.floor
local msin = math.sin
local mcos = math.cos
local mrandom = math.random
local twopi = 6.28318530718

-- Helper function
local function randomRange(base: number, range: number): number
	if range == 0 then
		return base
	end
	return base + (mrandom() - 0.5) * range
end

local function spawnParticle(sys: ParticleSystemNode, p: Particle)
	p.life = 0
	p.maxLife = mmax(0.1, randomRange(sys.life, sys.lifeVar))
	p.scale = mmax(0.0001, randomRange(sys.scale, sys.scaleVar))
	
	-- Uniform distribution inside the concentric ring centered at (0, 0)
	local r_in = sys.insideRadius
	local r_out = sys.outsideRadius
	local u = mrandom()
	local r = math.sqrt(u * (r_out * r_out - r_in * r_in) + r_in * r_in)
	local theta = mrandom() * twopi
	
	p.x = r * mcos(theta)
	p.y = r * msin(theta)
	
	if sys.artboard then
		p.instance = sys.artboard:instance()
	else
		p.instance = nil
	end
end

local function init(self: ParticleSystemNode, context: Context): boolean
	self.emitterPaint = Paint.with({
		style = "stroke",
		color = 0xFF00FF00,
		thickness = 1,
	})
	self.emitterPath = Path.new()
	self.particles = {}
	self.mat = Mat2D.identity()
	
	local targetCount = mfloor(self.count)
	if targetCount < 0 then targetCount = 0 end
	
	-- Determine spawn interval to spread births perfectly in time
	local avgLife = mmax(0.1, self.life)
	local interval = avgLife / mmax(1, targetCount)
	
	for i = 1, targetCount do
		local p: Particle = {
			x = 0,
			y = 0,
			scale = 1,
			life = 0,
			maxLife = 1,
			instance = nil,
			born = false,
			-- Spread birth times completely one-by-one, randomized within their own intervals
			delay = (i - 1) * interval + mrandom() * interval,
		}
		table.insert(self.particles, p)
	end
	
	return true
end

local function advance(self: ParticleSystemNode, seconds: number): boolean
	-- Adjust particle array size if count changes dynamically
	local currentCount = #self.particles
	local targetCount = mfloor(self.count)
	if targetCount < 0 then targetCount = 0 end
	
	if currentCount < targetCount then
		local addedCount = targetCount - currentCount
		local avgLife = mmax(0.1, self.life)
		local interval = avgLife / mmax(1, addedCount)
		for i = 1, addedCount do
			local p: Particle = {
				x = 0,
				y = 0,
				scale = 1,
				life = 0,
				maxLife = 1,
				instance = nil,
				born = false,
				delay = (i - 1) * interval + mrandom() * interval,
			}
			table.insert(self.particles, p)
		end
	elseif currentCount > targetCount then
		for _ = targetCount + 1, currentCount do
			local p = table.remove(self.particles)
			if p then
				p.instance = nil
			end
		end
	end

	-- Update active particles
	for i = 1, #self.particles do
		local p = self.particles[i]
		if not p.born then
			p.delay = p.delay - seconds
			if p.delay <= 0 then
				local overflow = -p.delay
				spawnParticle(self, p)
				p.born = true
				p.life = overflow % p.maxLife
				if p.instance and p.life > 0 then
					p.instance:advance(p.life)
				end
			end
		else
			p.life = p.life + seconds
			if p.life >= p.maxLife then
				local overflow = p.life - p.maxLife
				-- Respawn particle to keep continuous randomized emission
				spawnParticle(self, p)
				p.life = overflow % p.maxLife
				if p.instance and p.life > 0 then
					p.instance:advance(p.life)
				end
			elseif p.instance then
				p.instance:advance(seconds)
			end
		end
	end
	
	return true
end

local function draw(self: ParticleSystemNode, renderer: Renderer)
	local mat = self.mat

	-- Draw emitter ring (the concentric circles) if requested
	if self.drawEmitter then
		local ep = self.emitterPath
		ep:reset()
		
		local segments = 64
		local r_out = self.outsideRadius
		for i = 0, segments do
			local angle = (i / segments) * twopi
			local vx = mcos(angle) * r_out
			local vy = msin(angle) * r_out
			if i == 0 then
				ep:moveTo(Vector.xy(vx, vy))
			else
				ep:lineTo(Vector.xy(vx, vy))
			end
		end
		ep:close()
		
		local r_in = self.insideRadius
		for i = 0, segments do
			local angle = (i / segments) * twopi
			local vx = mcos(angle) * r_in
			local vy = msin(angle) * r_in
			if i == 0 then
				ep:moveTo(Vector.xy(vx, vy))
			else
				ep:lineTo(Vector.xy(vx, vy))
			end
		end
		ep:close()
		
		renderer:drawPath(ep, self.emitterPaint)
	end

	-- Draw and transform each active particle artboard
	for i = 1, #self.particles do
		local p = self.particles[i]
		if p.born then
			local instance = p.instance
			if not instance and self.artboard then
				instance = self.artboard:instance()
				p.instance = instance
			end
			if instance then
				renderer:save()
				local finalScale = p.scale
				mat.xx = finalScale
				mat.xy = 0
				mat.yx = 0
				mat.yy = finalScale
				mat.tx = p.x
				mat.ty = p.y
				renderer:transform(mat)
				instance:draw(renderer)
				renderer:restore()
			end
		end
	end
end

-- Return the node factory function
return function(): Node<ParticleSystemNode>
	return {
		artboard = late(),
		count = 30,
		insideRadius = 0,
		outsideRadius = 100,
		life = 3,
		lifeVar = 1,
		scale = 1,
		scaleVar = 0.5,
		drawEmitter = false,
		
		emitterPaint = late(),
		emitterPath = late(),
		particles = {},
		mat = late(),
		
		init = init,
		advance = advance,
		draw = draw,
	}
end

