-- ParticleSystem: Optimized Simple Rectangle Particle System
-- Relaxation radius parameter

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
	sizeX: Input<number>,
	sizeY: Input<number>,
	relaxationRadius: Input<number>,
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
local _msin = math.sin
local _mcos = math.cos
local mrandom = math.random
local _twopi = 6.28318530718

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
	
	local rRad = sys.relaxationRadius or 0
	local x, y = 0, 0
	local accepted = false
	
	if rRad > 0 then
		local rRadSq = rRad * rRad
		-- Rejection sampling (fast, reliable up to reasonable densities)
		for attempt = 1, 10 do
			x = (mrandom() - 0.5) * sys.sizeX
			y = (mrandom() - 0.5) * sys.sizeY
			
			local tooClose = false
			for j = 1, #sys.particles do
				local other = sys.particles[j]
				if other.born and other ~= p then
					local dx = x - other.x
					local dy = y - other.y
					if (dx * dx + dy * dy) < rRadSq then
						tooClose = true
						break
					end
				end
			end
			if not tooClose then
				accepted = true
				break
			end
		end
	end
	
	if not accepted then
		x = (mrandom() - 0.5) * sys.sizeX
		y = (mrandom() - 0.5) * sys.sizeY
	end
	
	p.x = x
	p.y = y
	
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

	-- Draw emitter rectangle if requested
	if self.drawEmitter then
		local ep = self.emitterPath
		ep:reset()
		
		local hx = self.sizeX / 2
		local hy = self.sizeY / 2
		
		ep:moveTo(Vector.xy(-hx, -hy))
		ep:lineTo(Vector.xy(hx, -hy))
		ep:lineTo(Vector.xy(hx, hy))
		ep:lineTo(Vector.xy(-hx, hy))
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
		sizeX = 100,
		sizeY = 100,
		relaxationRadius = 0,
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

