-- filepath: c:\Dropbox\Settings\Rive\Scripting\ParticlePhysics.lua
-- ParticleSystem: Physics-based particle emitter with collision
-- Type definitions
type Particle = {
	id: number,
	x: number,
	y: number,
	vx: number,
	vy: number,
	radius: number,
	instance: Artboard,
	isSleeping: boolean,
	sleepTimer: number,
	cx: number,
	cy: number,
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
	bounciness: Input<number>, -- 0.0 to 1.0 (bounciness)
	gravity: Input<number>,     -- positive = down
	sizeMultiplier: Input<number>,
	emitterRadius: Input<number>,
	emissionInterval: Input<number>, -- Emit every N frames
	
	boxWidth: Input<number>,
	boxHeight: Input<number>,
	boxY: Input<number>,        -- Vertical center of the box
	
	boxPath: Path,
	emitterPath: Path,
	boxPaint: Paint,
	emitterPaint: Paint,

	-- State
	particles: { Particle },
	packets: { Packet },
	packetIndex: number,
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
local SUBSTEPS = 3     -- Reduced slightly to save CPU
local BASE_RADIUS = 12 -- Base radius in pixels for size=1
local CELL_SIZE = 40   -- Size of spatial grid buckets
local FIXED_DT = 1/60  -- Target physics rate

local SLEEP_SPEED_SQ = 10 * 10 -- Speed threshold to consider sleeping
local SLEEP_TIME = 0.5         -- Time in seconds to trigger sleep

-- Generate the hardcoded emission packs
local function generatePackets()
	local packs = {}
	-- 30 bursts of particles
	for i = 1, 30 do
		table_insert(packs, {
			type = mrandom(1, 5),      -- Artboard type 1-5
			amount = mrandom(10, 100), -- Amount per burst (Using this as total amount to emit for the type now)
			size = mrandom(1, 2)                   -- Scale factor
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

	self.particles = {}
	self.packets = generatePackets()
	self.packetIndex = 1
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
	
	-- Circular emitter
	local angle = mrandom() * 2 * math.pi
	local r = msqrt(mrandom()) * self.emitterRadius
	local startX = r * mcos(angle)
	local startY = -400 + r * msin(angle) -- Emitter Y position (well above the box)
	
	instance:advance(0)
	table_insert(self.particles, {
		id = self.nextId,
		x = startX,
		y = startY,
		vx = 0,
		vy = 0,
		radius = radius,
		instance = instance,
		isSleeping = false,
		sleepTimer = 0,
		cx = 0,
		cy = 0,
	})
	self.nextId = self.nextId + 1
end

local function advance(self: ParticleSystemNode, seconds: number): boolean
	local dt = seconds

	-- 1. Emission Logic
	self.frameCounter = self.frameCounter + 1
	-- Emit every N frames
	local interval = math.max(1, math.floor(self.emissionInterval))
	
	if (self.frameCounter % interval == 0) and (self.packetIndex <= #self.packets) then
		local currentPacket = self.packets[self.packetIndex]
		if currentPacket.amount > 0 then
			spawnParticle(self, currentPacket)
			currentPacket.amount = currentPacket.amount - 1
		else
			self.packetIndex = self.packetIndex + 1
		end
	end
	
	-- 2. Physics Update (Fixed Timestep)
	local parts = self.particles
	local pCount = #parts
	if pCount == 0 then return true end

	-- We cap the accumulator to max 2 steps to simply slow down simulation 
	-- rather than trying to catch up if we are lagging.
	-- This behaves like "slow motion" when heavy instead of "exploding physics".
	local steps = 1
	if dt > FIXED_DT * 1.5 then steps = 2 end
	if dt > FIXED_DT * 2.5 then steps = 3 end -- Cap at 3 physics updates per frame

	local stepDt = FIXED_DT / SUBSTEPS

	local gravity = self.gravity
	local restitution = self.bounciness
	local friction = self.friction
	-- Map friction input 0..1 to a damping factor 1.0..0.0 per frame-ish
	local damping = math.max(0, 1.0 - friction) -- Stronger floor friction
	
	-- Box Boundaries
	local halfW = self.boxWidth / 2
	local halfH = self.boxHeight / 2
	local boxY = self.boxY
	local leftWall = -halfW
	local rightWall = halfW
	local floorY = boxY + halfH
	local topY = boxY - halfH -- Top of the open box
	
	-- Run physics steps
	for _ = 1, steps do
		for step = 1, SUBSTEPS do
			-- A. Build Grid
			self.grid = {}
			local grid = self.grid
			for i = 1, pCount do
				local p = parts[i]
				
				-- Cache grid position to ensure we check the bucket where we reside
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
			
			-- B. Update Particles
			for i = 1, pCount do
				local p = parts[i]
				
				-- Check for sleep eligibility
				local vSq = p.vx*p.vx + p.vy*p.vy
				if vSq < SLEEP_SPEED_SQ then
					p.sleepTimer = p.sleepTimer + stepDt
					if p.sleepTimer > SLEEP_TIME then
						p.isSleeping = true
						p.vx = 0
						p.vy = 0
					end
				else
					p.sleepTimer = 0
					p.isSleeping = false
				end

				-- If sleeping, skip integration
				if not p.isSleeping then
					-- Integrate Gravity
					p.vy = p.vy + gravity * stepDt
					
					-- Integrate Position
					p.x = p.x + p.vx * stepDt
					p.y = p.y + p.vy * stepDt
					
					-- Box Collision (U-Shape)
					-- Check Floor
					if p.y + p.radius > floorY then
						p.y = floorY - p.radius
						p.vy = -p.vy * restitution
						p.vx = p.vx * damping -- friction on floor
					end
					
					-- Check Walls (Left/Right) - only if within vertical bounds of the "box"
					if p.y > topY then
						 -- Simple containment logic: Force inside
						if p.x - p.radius < leftWall then
							p.x = leftWall + p.radius
							-- Force velocity positive (right)
							p.vx = math.abs(p.vx) * restitution
						elseif p.x + p.radius > rightWall then
							p.x = rightWall - p.radius
							-- Force velocity negative (left)
							p.vx = -math.abs(p.vx) * restitution
						end
					end
				end

				-- Particle-Particle Collision (Grid optimized)
				-- Check current cell and immediate neighbors (3x3 area)
				local cx = p.cx 
				local cy = p.cy
				
				for nx = cx - 1, cx + 1 do
					for ny = cy - 1, cy + 1 do
						local nKey = nx * 73856093 + ny * 19349663
						local cell = grid[nKey]
						if cell then
							for j = 1, #cell do
								local other = cell[j]
								 -- Optimization: Check ID to avoid double checks (A vs B, then B vs A)
								if other.id > p.id and not (p.isSleeping and other.isSleeping) then
									local dx = other.x - p.x
									local dy = other.y - p.y
									local distSq = dx*dx + dy*dy
									local radSum = p.radius + other.radius
									
									-- Collision detected
									if distSq < radSum * radSum and distSq > 0.0001 then
										local dist = msqrt(distSq)
										local pen = (radSum - dist) * 0.5
										local nx_ = dx / dist
										local ny_ = dy / dist
										
										-- Separate
										if not p.isSleeping then
											p.x = p.x - nx_ * pen
											p.y = p.y - ny_ * pen
										end
										if not other.isSleeping then
											other.x = other.x + nx_ * pen
											other.y = other.y + ny_ * pen
										end

										-- If one was sleeping but got pushed hard, wake it (velocity will do it next frame, 
										-- but separation ensures they aren't inside each other)
										
										-- Bounce (Impulse)
										local rvx = other.vx - p.vx
										local rvy = other.vy - p.vy
										local velAlongNormal = rvx * nx_ + rvy * ny_
										
										if velAlongNormal < 0 then
											local j = -(1 + restitution) * velAlongNormal
											j = j * 0.5 -- Equal mass assumption
											
											local ix = j * nx_
											local iy = j * ny_
											
											-- Friction (Tangential Impulse)
											local tx_ = -ny_
											local ty_ = nx_
											local velAlongTangent = rvx * tx_ + rvy * ty_
											local jt = -velAlongTangent * friction
											local ix_f = jt * tx_ * 0.5 
											local iy_f = jt * ty_ * 0.5
											
											if not p.isSleeping then
												p.vx = p.vx - ix - ix_f
												p.vy = p.vy - iy - iy_f
											end
											if not other.isSleeping then
												other.vx = other.vx + ix + ix_f
												other.vy = other.vy + iy + iy_f
											end
										end
									end
								end
							end
						end
					end
				end
				
				-- General Damping (Air resistance)
				p.vx = p.vx * 0.999
				p.vy = p.vy * 0.999
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

	local parts = self.particles
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
		
		friction = 0.9,
		bounciness = 0.5,
		gravity = 1000,
		sizeMultiplier = 0.5,
		emitterRadius = 5.0,
		emissionInterval = 3,
		
		boxWidth = 150,
		boxHeight = 700,
		boxY = 200,
		
		boxPath = Path.new(),
		emitterPath = Path.new(),
		boxPaint = Paint.new(),
		emitterPaint = Paint.new(),

		particles = {},
		packets = {},
		packetIndex = 1,
		frameCounter = 0,
		mat = late(),
		grid = {},

		nextId = 1,
		
		init = init,
		advance = advance,
		draw = draw,
	}
end

