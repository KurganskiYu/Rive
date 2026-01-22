-- Rive Particle System with Position-Based Dynamics (PBD) and Collision
-- Type definitions
type Particle = {
	id: number,
	x: number,
	y: number,
	prevX: number,
	prevY: number,
	vx: number,
	vy: number,
	radius: number,
	instance: Artboard,
	cx: number,
	cy: number,
	sleeping: boolean,
	sleepTimer: number,
}

type Packet = {
	type: number,
	amount: number,
	size: number
}

type ParticleSystemNode = {
	-- Inputs
	artboard1: Input<Artboard>,
	artboard2: Input<Artboard>,
	artboard3: Input<Artboard>,
	artboard4: Input<Artboard>,
	artboard5: Input<Artboard>,
	
	friction: Input<number>,    -- 0.0 to 1.0 (velocity damping on contact/air)
	damping: Input<number>,     -- Air resistance (0.0 to 1.0)
	gravity: Input<number>,     -- positive = down
	sizeMultiplier: Input<number>,
	emitterRadius: Input<number>,
	emissionInterval: Input<number>, -- Emit every N frames
	initialVelocityY: Input<number>,
	
	boxWidth: Input<number>,
	boxHeight: Input<number>,
	boxY: Input<number>,        -- Vertical center of the box
	
	boxPath: Path,
	emitterPath: Path,
	boxPaint: Paint,
	emitterPaint: Paint,

	-- State
	-- Use _particles for internal Lua storage to avoid host type conflicts
	_particles: { Particle },
	packets: { Packet },
	packetIndex: number,
	packetDelayCounter: number,
	frameCounter: number,
	mat: Mat2D,
	
	-- Optimization Grid
	grid: { { Particle } },
	nextId: number,
}

-- Math shortcuts
local msin = math.sin
local mcos = math.cos
local mfloor = math.floor
local msqrt = math.sqrt
local mrandom = math.random
local table_insert = table.insert

-- Constants
local SUBSTEPS = 8     -- Increased substeps for PBD stability
local BASE_RADIUS = 10 -- Base radius in pixels for size=1
local CELL_SIZE = 40   -- Size of spatial grid buckets
local MAX_VELOCITY = 1500 -- Cap max speed to prevent explosions
local SLEEP_VELOCITY_THRESH = 15 -- Velocity threshold for sleeping
local SLEEP_TIME_THRESH = 1.0    -- Time to wait before sleeping

-- Generate the hardcoded emission packs
local function generatePackets()
	local packs = {}
	-- 30 packs of particles
	for i = 1, 30 do
		table_insert(packs, {
			type = mrandom(1, 5),      -- Artboard type 1-5
			amount = mrandom(3, 30),   -- Reduced amount per pack to minimize initial overlap
			size = mrandom(1, 2)       -- Scale factor
		})
	end
	return packs
end


local function init(self: ParticleSystemNode, context: Context): boolean
	self.boxPath = Path.new()
	self.emitterPath = Path.new()
	
	self.boxPaint = Paint.with({
		style = 'stroke',
		color = 0xFF000000,
		thickness = 1,
	})
	
	self.emitterPaint = Paint.with({
		style = 'fill',
		color = 0xFF000000, -- Black 
	})

	self._particles = {}
	self.packets = generatePackets()
	self.packetIndex = 1
	self.packetDelayCounter = 0
	self.frameCounter = 0
	self.mat = Mat2D.identity()
	self.grid = {}
	self.nextId = 1
	-- Seed random for consistency or variation
	math.randomseed(os.time())
	return true
end

local function spawnParticle(self: ParticleSystemNode, packet: Packet)
	local typeIdx = packet.type
	local inputAb
	if typeIdx == 1 then inputAb = self.artboard1
	elseif typeIdx == 2 then inputAb = self.artboard2
	elseif typeIdx == 3 then inputAb = self.artboard3
	elseif typeIdx == 4 then inputAb = self.artboard4
	else inputAb = self.artboard5 end
	
	-- Helper to verify input is connected
	local instance = inputAb:instance()
	if not instance then return end
	
	local radius = BASE_RADIUS * packet.size * self.sizeMultiplier
	
	-- Attempt to find a non-overlapping position
	local startX: number = 0
	local startY: number = -400
	local valid = false
	local grid = self.grid
	
	for attempt = 1, 10 do
		local angle = mrandom() * 2 * math.pi
		local r = msqrt(mrandom()) * self.emitterRadius
		
		startX = r * mcos(angle)
		startY = -400 + r * msin(angle)
		
		-- Check collision with existing particles in grid
		local overlap = false
		
		-- Check grid neighborhood
		if next(grid) ~= nil then
			local ix = mfloor((startX + 100000) / CELL_SIZE)
			local iy = mfloor((startY + 100000) / CELL_SIZE)
			
			for nx = ix - 1, ix + 1 do
				for ny = iy - 1, iy + 1 do
					local nKey = nx * 73856093 + ny * 19349663
					local cell = grid[nKey]
					if cell then
						for j = 1, #cell do
							local other = cell[j]
							local dx = startX - other.x
							local dy = startY - other.y
							local distSq = dx*dx + dy*dy
							local radSum = radius + other.radius
							if distSq < radSum * radSum then
								overlap = true
								break
							end
						end
					end
					if overlap then break end
				end
				if overlap then break end
			end
		end
		
		if not overlap then
			valid = true
			break
		end
	end
	
	-- If we couldn't find a spot effectively, push it up high to avoid immediate explosion
	if not valid then
		-- Fallback: Place it higher up so it falls into place? 
		-- Or just accept the conflict but with zero velocity (which we do anyway).
		-- Pushing it up:
		startY = -450 - (mrandom() * 50) 
		-- We keep startX from the last attempt
	end
	
	instance:advance(0)
	
	local newParticle: Particle = {
		id = self.nextId,
		x = startX,
		y = startY,
		prevX = startX,
		prevY = startY,
		vx = 0,
		vy = self.initialVelocityY,
		radius = radius,
		instance = instance,
		cx = 0,
		cy = 0,
		sleeping = false,
		sleepTimer = 0,
	}
	
	-- Use explicit table insert on internal storage
	if not self._particles then self._particles = {} end
	table_insert(self._particles, newParticle)
	
	self.nextId = self.nextId + 1
end

local function advance(self: ParticleSystemNode, seconds: number): boolean
	local dt = seconds
	if dt > 0.05 then dt = 0.05 end -- Cap dt

	-- Sleep Logic
	local parts = self._particles
	if parts then
		for i = 1, #parts do
			local p = parts[i]
			if not p.sleeping then
				local speedSq = p.vx * p.vx + p.vy * p.vy
				if speedSq < SLEEP_VELOCITY_THRESH * SLEEP_VELOCITY_THRESH then
					p.sleepTimer = p.sleepTimer + dt
					if p.sleepTimer > SLEEP_TIME_THRESH then
						p.sleeping = true
						-- Fix position
						p.vx = 0
						p.vy = 0
					end
				else
					p.sleepTimer = 0
				end
			end
		end
	end

	-- 1. Emission Logic
	self.frameCounter = self.frameCounter + 1
	-- Emit every N frames
	local interval = math.max(1, math.floor(self.emissionInterval))
	
	if self.packetIndex <= #self.packets then
		if self.packetDelayCounter > 0 then
			self.packetDelayCounter = self.packetDelayCounter - 1
		elseif self.frameCounter % interval == 0 then
			local currentPacket = self.packets[self.packetIndex]
			if currentPacket.amount > 0 then
				spawnParticle(self, currentPacket)
				currentPacket.amount = currentPacket.amount - 1
			end
			
			if currentPacket.amount <= 0 then
				self.packetIndex = self.packetIndex + 1
				self.packetDelayCounter = 30
			end
		end
	end
	
	-- 2. Physics Update (PBD)
	local parts = self._particles
	if not parts then return true end
	
	local pCount = #parts
	if pCount == 0 then return true end

	local substeps = SUBSTEPS
	local subDt = dt / substeps

	local gravity = self.gravity
	local friction = self.friction -- Used for ground contact
	local damping = self.damping   -- Air resistance per substep
	-- Safety: Ensure excessively high time steps don't break stability
	if subDt > 0.01 then subDt = 0.01 end

	-- Box Boundaries
	local halfW = self.boxWidth / 2
	local halfH = self.boxHeight / 2
	local boxY = self.boxY
	local leftWall = -halfW
	local rightWall = halfW
	local floorY = boxY + halfH
	local topY = boxY - halfH 
	
	-- Run physics steps
	for step = 1, substeps do
		-- A. Integration (Prediction)
		for i = 1, pCount do
			local p = parts[i]
			if not p.sleeping then
				p.prevX = p.x
				p.prevY = p.y
				
				p.vy = p.vy + gravity * subDt
				p.x = p.x + p.vx * subDt
				p.y = p.y + p.vy * subDt
			end
		end

		-- B. Constraint Solving
		-- Rebuild Grid
		self.grid = {}
		local grid = self.grid
		for i = 1, pCount do
			local p = parts[i]
			
			local ix = mfloor((p.x + 100000) / CELL_SIZE)
			local iy = mfloor((p.y + 100000) / CELL_SIZE)
			p.cx = ix
			p.cy = iy

			local key = ix * 73856093 + iy * 19349663
			local cell = grid[key]
			if not cell then
				cell = {}
				grid[key] = cell
			end
			table_insert(cell, p)
		end
		
		-- Solve Particles & Walls
		for i = 1, pCount do
			local p = parts[i]

			-- Particle-Particle (Grid)
			local cx, cy = p.cx, p.cy
			for nx = cx - 1, cx + 1 do
				for ny = cy - 1, cy + 1 do
					local nKey = nx * 73856093 + ny * 19349663
					local cell = grid[nKey]
					if cell then
						for j = 1, #cell do
							local other = cell[j]
							if other.id > p.id then
								local dx = other.x - p.x
								local dy = other.y - p.y
								local distSq = dx*dx + dy*dy
								local radSum = p.radius + other.radius
								
								if distSq < radSum * radSum and distSq > 0.0001 then
									local dist = msqrt(distSq)
									local stiffness = 0.8
									local totalPen = (radSum - dist) * stiffness
									local nx_ = dx / dist
									local ny_ = dy / dist
									
									if not p.sleeping and not other.sleeping then
										local halfPen = totalPen * 0.5
										p.x = p.x - nx_ * halfPen
										p.y = p.y - ny_ * halfPen
										other.x = other.x + nx_ * halfPen
										other.y = other.y + ny_ * halfPen
									elseif not p.sleeping and other.sleeping then
										p.x = p.x - nx_ * totalPen
										p.y = p.y - ny_ * totalPen
									elseif p.sleeping and not other.sleeping then
										other.x = other.x + nx_ * totalPen
										other.y = other.y + ny_ * totalPen
									end
								end
							end
						end
					end
				end
			end
			
			-- Box Constraints
			if not p.sleeping then
				-- Floor
				if p.y + p.radius > floorY then
					p.y = floorY - p.radius
					 -- Position-based friction
					local moveX = p.x - p.prevX
					p.x = p.x - moveX * (friction * 0.5)
				end
				
				-- Walls
				if p.y > topY then
					if p.x - p.radius < leftWall then
						p.x = leftWall + p.radius
					elseif p.x + p.radius > rightWall then
						p.x = rightWall - p.radius
					end
				end
			end
		end -- end particle loop

		-- C. Velocity Update
		for i = 1, pCount do
			local p = parts[i]
			if not p.sleeping then
				local vx = (p.x - p.prevX) / subDt * damping
				local vy = (p.y - p.prevY) / subDt * damping

				-- Clamp velocity to prevent explosions
				if vx > MAX_VELOCITY then vx = MAX_VELOCITY elseif vx < -MAX_VELOCITY then vx = -MAX_VELOCITY end
				if vy > MAX_VELOCITY then vy = MAX_VELOCITY elseif vy < -MAX_VELOCITY then vy = -MAX_VELOCITY end

				p.vx = vx
				p.vy = vy
			end
		end
	end
	
	-- 3. Update Graphics
	for i = 1, pCount do
		parts[i].instance:advance(seconds)
	end

	return true
end

local function draw(self: ParticleSystemNode, renderer: Renderer)
	-- Draw Box
	self.boxPath:reset()
	local hw = self.boxWidth / 2
	local hh = self.boxHeight / 2
	local y = self.boxY
	self.boxPath:moveTo(Vector.xy(-hw, y - hh))
	self.boxPath:lineTo(Vector.xy(hw, y - hh))
	self.boxPath:lineTo(Vector.xy(hw, y + hh))
	self.boxPath:lineTo(Vector.xy(-hw, y + hh))
	self.boxPath:close()
	renderer:drawPath(self.boxPath, self.boxPaint)

	-- Draw Emitter
	self.emitterPath:reset()
	--self.emitterPath:circle(0, -400, self.emitterRadius) -- not working in Rive yet
	renderer:drawPath(self.emitterPath, self.emitterPaint)

	local parts = self._particles
	if not parts then return end
	
	local mat = self.mat
	for i = 1, #parts do
		local p = parts[i]
		renderer:save()
		mat.xx = p.radius / BASE_RADIUS -- Scale based on radius relative to base
		mat.yy = mat.xx
		mat.tx = p.x
		mat.ty = p.y
		renderer:transform(mat)
		p.instance:draw(renderer)
		renderer:restore()
	end
end

return function(): Node<ParticleSystemNode>
	return {
		artboard1 = late(),
		artboard2 = late(),
		artboard3 = late(),
		artboard4 = late(),
		artboard5 = late(),
		
		friction = 0.5,           -- Reduced default friction
		damping = 0.985,          -- Default air resistance
		gravity = 1500,           -- Increased gravity for snappier fall
		sizeMultiplier = 0.5,
		emitterRadius = 80.0,     -- Increased emitter radius to spread particles
		emissionInterval = 5,     -- Slower emission
		initialVelocityY = 0,
		
		boxWidth = 150,
		boxHeight = 700,
		boxY = 200,
		
		boxPath = Path.new(),
		emitterPath = Path.new(),
		boxPaint = Paint.new(),
		emitterPaint = Paint.new(),

		_particles = {},
		packets = {},
		packetIndex = 1,
		packetDelayCounter = 0,
		frameCounter = 0,
		mat = late(),
		grid = {},

		nextId = 1,
		
		init = init,
		advance = advance,
		draw = draw,
	}
end

