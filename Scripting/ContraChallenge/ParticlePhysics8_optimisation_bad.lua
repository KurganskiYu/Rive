-- Rive Particle System with Position-Based Dynamics (PBD) and Collision
--COMMON PRACTICES & RESTRICTIONS
----------------------------------
-- "Safe" Random: Scripts often use `math.random` standard Lua library.
-- Typed Arrays: Use generic syntax in comments like `{ SegmentEntry }` or `{ [number]: number }`.
-- State Management: Keep state in the `self` object or ViewModel types.
-- Modularity: `require('Module')` is supported (e.g., `require('Physics')`).
-- Type Safety: Inputs are strictly typed. 
-- Local Table Typing: When defining an empty table that will hold structured data or be used with `table.insert`, explicitly type it to aid the compiler.
--  Example: `local groups: { [number]: {Particle} } = {}` ensures `groups` is treated correctly as a map of arrays.
-- Context: `context:markNeedsUpdate()` can be used to request redraws (seen in PathEffect).
----------------------------------


-- Type definitions
type ParticleVM = {
	time: Property<string>,
	pointerOver: Property<boolean>,
}

type Particle = {
	id: number,
	clusterId: number,
	x: number,
	y: number,
	prevX: number,
	prevY: number,
	vx: number,
	vy: number,
	radius: number,
	originalRadius: number,
	instance: Artboard<ParticleVM>,
	-- cx, cy removed (unused)
	sleeping: boolean,
	sleepTimer: number,
	targetX: number,
	targetY: number,
	-- Animation
	currentT: number, -- 0.0 to 1.0 interpolation factor
	easedT: number,   -- Cached ease value
	relaxRadius: number, -- Cached collision radius for relaxation
	
	-- Cached Props
	pointerOverProp: Property<boolean> | nil,
}

-- Toggle for expensive visual debugging
local DRAW_DEBUG_CLUSTERS = false

type Packet = {
	type: number,
	amount: number,
	size: number
}

type ParticleSystemNode = {
	-- Inputs
	artboard1: Input<Artboard<ParticleVM>>,
	artboard2: Input<Artboard<ParticleVM>>,
	artboard3: Input<Artboard<ParticleVM>>,
	artboard4: Input<Artboard<ParticleVM>>,
	artboard5: Input<Artboard<ParticleVM>>,
	
	friction: Input<number>,    -- 0.0 to 1.0 (velocity damping on contact/air)
	damping: Input<number>,     -- Air resistance (0.0 to 1.0)
	gravity: Input<number>,     -- positive = down
	sizeMultiplier: Input<number>,
	emitterWidth: Input<number>,
	emitterY: Input<number>,
	emissionInterval: Input<number>, -- Emit every N frames
	packetGap: Input<number>,        -- Frames between packs
	initialVelocityY: Input<number>,
	growDuration: Input<number>, -- Time in seconds to reach full expansion
	interactionRadius: Input<number>, -- Radius of influence for exploded view
	relaxPadding: Input<number>, -- Extra spacing between particles during relax
	relaxInteractionPadding: Input<number>, -- Additional padding for interacting particles
	
	outlineExpansion: Input<number>,
	
	globalClusterStrength: Input<number>,
	activeClusterStrength: Input<number>,

	boxWidth: Input<number>,
	boxHeight: Input<number>,
	boxY: Input<number>,        -- Vertical center of the box
	
	boxPath: Path,
	emitterPath: Path,
	boxPaint: Paint,
	emitterPaint: Paint,
	clusterPaint: Paint,
	clusterFillPaint: Paint,
	clusterPath: Path,

	-- State
	-- Use _particles for internal Lua storage to avoid host type conflicts
	_particles: { Particle },
	_clusters: { [number]: { Particle } }, -- Added: Cached clusters
	packets: { Packet },
	packetIndex: number,
	packetDelayCounter: number,
	frameCounter: number,
	mat: Mat2D,
	
	-- Optimization Grid
	grid: { [number]: { Particle } }, -- Fixed: Keyed by number hash
	gridKeys: { number },   -- Track used grid keys for fast clearing
	artboards: { Input<Artboard<ParticleVM>> }, -- Cached inputs
	
	nextId: number,
	lastSpawnX: number | nil,
	spawnDirection: number,
	
	-- Interaction
	positionsCaptured: boolean,
	selectedParticle: Particle | nil,
	activeClusterId: number | nil,
	clusterIntensity: number,
	pointerPos: {x: number, y: number}, -- Track pointer for dragging
}

-- Math shortcuts
local msin = math.sin
local mcos = math.cos
local mfloor = math.floor
local msqrt = math.sqrt
local mrandom = math.random
local mabs = math.abs
local matan2 = math.atan2
local mmin = math.min
local mmax = math.max
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort

-- Constants
local SUBSTEPS = 8     -- Increased substeps for PBD stability
local BASE_RADIUS = 10 -- Base radius in pixels for size=1
local CELL_SIZE = 40   -- Size of spatial grid buckets
local MAX_VELOCITY = 1500 -- Cap max speed to prevent explosions
local SLEEP_VELOCITY_THRESH = 15 -- Velocity threshold for sleeping
local SLEEP_VEL_SQ = SLEEP_VELOCITY_THRESH * SLEEP_VELOCITY_THRESH
local SLEEP_TIME_THRESH = 1.0    -- Time to wait before sleeping

-- Grid Hash Constants
local GRID_P1 = 73856093
local GRID_P2 = 19349663
local GRID_OFFSETS = {
	-GRID_P1 - GRID_P2, -GRID_P2, GRID_P1 - GRID_P2,
	-GRID_P1,           0,        GRID_P1,
	-GRID_P1 + GRID_P2, GRID_P2,  GRID_P1 + GRID_P2
}


-- Helper: Clear and rebuild spatial grid
-- Uses persistent tables to minimize garbage collection
local function buildGrid(self: ParticleSystemNode, particles: {Particle}, cellSize: number)
	local grid = self.grid
	local usedKeys = self.gridKeys
	
	-- 1. Fast clear of used cells
	for i = 1, #usedKeys do
		local key = usedKeys[i]
		local cell = grid[key]
		if cell then
			-- clear array (faster than creating new table)
			local cCount = #cell
			for j = cCount, 1, -1 do -- clearer counting
				cell[j] = nil 
			end
		end
		usedKeys[i] = nil
	end
	
	-- 2. Populate
	local count = #particles
	for i = 1, count do
		local p = particles[i]
		-- Cache grid coordinates on particle for fast lookup
		local ix = mfloor(p.x / cellSize)
		local iy = mfloor(p.y / cellSize)
		
		local key = ix * GRID_P1 + iy * GRID_P2
		local cell = grid[key]
		if not cell then
			local newCell: {Particle} = {}
			grid[key] = newCell
			cell = newCell
		end
		
		-- Track key if it's the first time we use it this frame/session
		if #cell == 0 then
			usedKeys[#usedKeys + 1] = key
		end
		
		cell[#cell + 1] = p
	end
	return grid
end

-- Generate the hardcoded emission packs
local function generatePackets()
	local packs = {}
	local np = 500
	local totalParticles = 0
	while totalParticles < np do
		local amount = mrandom(5, 28)
		if totalParticles + amount > np then
			amount = np - totalParticles
		end
		table_insert(packs, {
			type = mrandom(1, 5),      			-- Artboard type 1-5
			amount = amount,   			-- Adjusted to reach total of 600 particles
			size = 1.0 + (mrandom(0, 6) * 0.1)  -- Scale factor
		})
		totalParticles = totalParticles + amount
	end
	return packs
end


local function init(self: ParticleSystemNode, context: Context): boolean
	self.boxPath = Path.new()
	self.emitterPath = Path.new()
	
	self.boxPaint = Paint.with({
		style = 'stroke',
		color = 0xFF000000,
		thickness = 0,
	})
	
	self.emitterPaint = Paint.with({
		style = 'stroke',
		color = 0x80FFFFFF,  
		thickness = 3.0,
		cap = 'round',
	})

	self.clusterPath = Path.new()
	self.clusterPaint = Paint.with({
		style = 'stroke',
		color = 0x00FFFFFF, 
		thickness = 0.5,
		join = 'round',
		cap = 'round',
	})

	self.clusterFillPaint = Paint.with({
		style = 'fill',
		color = 0x00000000, 
		feather = 8.0,
	})

	self._particles = {}
	self._clusters = {} -- Initialize cluster cache
	self.packets = generatePackets()
	self.packetIndex = 1
	self.packetDelayCounter = 0
	self.frameCounter = 0
	self.mat = Mat2D.identity()
	self.grid = {}
	self.gridKeys = {}
	self.artboards = {
		self.artboard1,
		self.artboard2,
		self.artboard3,
		self.artboard4,
		self.artboard5
	}

	self.nextId = 1
	self.lastSpawnX = nil -- Changed magic number to nil
	self.spawnDirection = 1
	-- Seed random for consistency or variation
	math.randomseed(os.time())
	return true
end

local function spawnParticle(self: ParticleSystemNode, packet: Packet)
	local typeIdx = packet.type
	local inputAb = self.artboards[typeIdx]
	
	-- Helper to verify input is connected
	local instance = nil
	if inputAb then instance = inputAb:instance() end
	if not instance then return end
	
	local radius = BASE_RADIUS * packet.size * self.sizeMultiplier
	local width = self.emitterWidth
	local halfWidth = width / 2
	local startY = self.emitterY
	
	-- Initialize start position if needed
	local lastX = self.lastSpawnX or -halfWidth

	local startX = 0
	
	-- Logic: left-to-right then right-to-left
	if self.spawnDirection == 1 then
		-- Moving Right
		if lastX + 2*radius <= halfWidth then
			startX = lastX + radius
			lastX = startX + radius
		else
			-- Switch to Moving Left
			self.spawnDirection = -1
			lastX = halfWidth
			startX = lastX - radius
			lastX = startX - radius
		end
	else
		-- Moving Left
		if lastX - 2*radius >= -halfWidth then
			startX = lastX - radius
			lastX = startX - radius
		else
			-- Switch to Moving Right
			self.spawnDirection = 1
			lastX = -halfWidth
			startX = lastX + radius
			lastX = startX + radius
		end
	end
	
	self.lastSpawnX = lastX
	
	instance:advance(0)
	
	local newParticle: Particle = {
		id = self.nextId,
		clusterId = self.packetIndex,
		x = startX,
		y = startY,
		prevX = startX,
		prevY = startY,
		vx = 0,
		vy = self.initialVelocityY,
		radius = radius,
		originalRadius = radius,
		instance = instance,
		sleeping = false,
		sleepTimer = 0,
		targetX = startX,
		targetY = startY,
		currentT = 0,
		easedT = 0,
		relaxRadius = radius,
		pointerOverProp = nil,
	}
	
	-- Initialize ViewModel state
	if instance.data then
		if instance.data.time then
			local h = mrandom(1, 12)
			local m = mrandom(0, 59)
			instance.data.time.value = string.format("%d:%02d", h, m)
		end
		if instance.data.pointerOver then
			instance.data.pointerOver.value = false
			newParticle.pointerOverProp = instance.data.pointerOver
		end
	end
	
	-- Use explicit table insert on internal storage
	if not self._particles then self._particles = {} end
	-- Optimization: Direct array usage is slightly faster than table.insert
	local parts = self._particles
	parts[#parts + 1] = newParticle

	-- Add to cluster cache
	if not self._clusters then self._clusters = {} end
	local cid = newParticle.clusterId -- Fixed: Defined 'cid'
	if not self._clusters[cid] then self._clusters[cid] = {} end
	local cluster = self._clusters[cid]
	cluster[#cluster + 1] = newParticle
	
	self.nextId = self.nextId + 1
end

-- Relax Algorithm: Solves constraints without velocity integration
local function relax(self: ParticleSystemNode, dt: number)
	local parts = self._particles
	if not parts then return end
	local pCount = #parts
	if pCount == 0 then return end

	-- Cluster Forces: Attract to nearest neighbor in same cluster
	do
		local globStr = self.globalClusterStrength
		local actStr = self.activeClusterStrength
		local actId = self.activeClusterId
		local intensity = self.clusterIntensity
		local selected = self.selectedParticle

		-- Use cached clusters
		local clusters = self._clusters or {}

		-- 2. Apply forces
		for cid, cluster in ipairs(clusters) do
			local strength = globStr
			local isActiveCluster = (cid == actId)
			
			if isActiveCluster then
				strength = strength + actStr * intensity
			end

			if strength > 0.001 then
				local cSize = #cluster
				if cSize > 1 then
					for i = 1, cSize do
						local p = cluster[i]
						-- Skip cluster force for the selected particle (it interacts via pointer)
						if p ~= selected then
							local minDistSq = 1000000000 -- large number
							local nearest = nil
							
							-- Find nearest neighbor in same cluster
							for j = 1, cSize do
								if i ~= j then
									local other = cluster[j]
									local dx = other.x - p.x
									local dy = other.y - p.y
									local dsq = dx*dx + dy*dy
									if dsq < minDistSq then
										minDistSq = dsq
										nearest = other
									end
								end
							end
							
								-- Forces Calculation
							local moveX = 0
							local moveY = 0
							local forceCount = 0

							-- A. Attraction to Nearest Neighbor (Cohesion)
							if nearest then
								moveX = moveX + (nearest.x - p.x)
								moveY = moveY + (nearest.y - p.y)
								forceCount = forceCount + 1
							end
							
							-- B. Attraction to Active Particle (if active and not already the nearest)
							-- This ensures the whole cluster follows the leader even if strung out
							if isActiveCluster and selected and nearest ~= selected then
								moveX = moveX + (selected.x - p.x)
								moveY = moveY + (selected.y - p.y)
								forceCount = forceCount + 1
							end

							-- Apply Combined Forces
							if forceCount > 0 then
								-- Average the direction if multiple attractors
								moveX = moveX / forceCount
								moveY = moveY / forceCount
								
								local f = strength * dt
								if f > 0.5 then f = 0.5 end -- cap force for stability
								
								p.x = p.x + moveX * f
								p.y = p.y + moveY * f
							end
						end
					end
				end
			end
		end
	end

	local basePadding = self.relaxPadding
	local interactPadding = self.relaxInteractionPadding
	local sel = self.selectedParticle
	local actId = self.activeClusterId
	
	-- Apply Homing Force (Pull to original positions)
	if self.positionsCaptured then
		local returnSpeed = 5.0 -- Speed of return to original position
		local factor = returnSpeed * dt
		if factor > 1 then factor = 1 end
		
		local globStr = self.globalClusterStrength
		local actStr = self.activeClusterStrength
		local intensity = self.clusterIntensity
		
		for i = 1, pCount do
			local p = parts[i]
			-- Skip selected particle from homing, user controls it
			if p ~= sel then
				-- Calculate effective cluster strength to reduce jittery conflict
				local cStr = globStr
				if p.clusterId == actId then
					cStr = cStr + actStr * intensity
				end
				
				-- Proportionally decrease position force when clustering force increases
				-- If strength >= 1, homing is 0.
				local homingMult = 1.0 - cStr
				if homingMult < 0 then homingMult = 0 end

				-- Jitter fix: Reduce homing force if particle is interacting/growing
				local ease = p.easedT
				local strength = (1.0 - ease) * homingMult
				
				if strength > 0.01 then
					local f = factor * strength
					p.x = p.x + (p.targetX - p.x) * f
					p.y = p.y + (p.targetY - p.y) * f
				end
			end
		end
	end

	local substeps = 4 -- Fewer steps needed for relaxation
	
	-- Optimization: Build grid ONCE for relaxation steps
	local grid = buildGrid(self, parts, CELL_SIZE)

	for step = 1, substeps do
		-- Solve Overlaps
		for i = 1, pCount do
			local p = parts[i]
			
				-- Cache particle properties to avoid table lookups in inner loop
			local pid = p.id
			local px = p.x
			local py = p.y
			local pr = p.relaxRadius

			-- Look up neighbours using cached grid coords (re-calc logical coord to handle small movement)
			-- NOTE: We use coordinates derived from current position to check against static grid
			-- This is an approximation but much faster than rebuilding grid every substep.
			local cx = mfloor(px / CELL_SIZE)
			local cy = mfloor(py / CELL_SIZE)
			local baseKey = cx * GRID_P1 + cy * GRID_P2

			for k = 1, 9 do
				local nKey = baseKey + GRID_OFFSETS[k]
				local cell = grid[nKey]
				if cell then
					for j = 1, #cell do
						local other = cell[j]
						if other.id > pid then
							local dx = other.x - px
							local dy = other.y - py
							local distSq = dx*dx + dy*dy
							
							-- Use pre-calculated relaxRadius (includes padding)
							local radSum = pr + other.relaxRadius
							
							if distSq < radSum * radSum and distSq > 0.0001 then
								local dist = msqrt(distSq)
								local totalPen = radSum - dist
								local nx_ = dx / dist
								local ny_ = dy / dist
								
								-- Modification: Selected particle has infinite mass (does not move)
								if p == sel then
									other.x = other.x + nx_ * totalPen
									other.y = other.y + ny_ * totalPen
								elseif other == sel then
									p.x = p.x - nx_ * totalPen
									p.y = p.y - ny_ * totalPen
								else
									local factor = 0.5
									p.x = p.x - nx_ * totalPen * factor
									p.y = p.y - ny_ * totalPen * factor
									other.x = other.x + nx_ * totalPen * factor
									other.y = other.y + ny_ * totalPen * factor
								end
							end
						end
					end
				end
			end
		end
	end
	
	-- Sync previous positions to prevent velocity jumps when physics resumes
	for i = 1, pCount do
		local p = parts[i]
		p.prevX = p.x
		p.prevY = p.y
		-- Zero out velocity explicitly as well
		p.vx = 0
		p.vy = 0
	end
end

local function pointerDown(self: ParticleSystemNode, event: PointerEvent)
	local parts = self._particles
	if not parts then return end
	
	local pos = event.position
	-- Update in place to avoid table creation
	self.pointerPos.x = pos.x
	self.pointerPos.y = pos.y

	-- Find clicked particle (simple linear check is fast enough for clicks < 1000 items)
	for i = #parts, 1, -1 do
		local p = parts[i]
		local dx = pos.x - p.x
		local dy = pos.y - p.y
		if dx*dx + dy*dy <= p.radius * p.radius then
			self.selectedParticle = p
			self.activeClusterId = p.clusterId
			self.clusterIntensity = 0.0 -- Reset ramp
			event:hit() -- Consume event
			return
		end
	end
end

local function pointerUp(self: ParticleSystemNode, event: PointerEvent)
	self.selectedParticle = nil
	self.activeClusterId = nil
end

local function pointerMove(self: ParticleSystemNode, event: PointerEvent)
	local pos = event.position
	-- Update in place
	self.pointerPos.x = pos.x
	self.pointerPos.y = pos.y
	
	if self.selectedParticle then
		self.selectedParticle.x = pos.x
		self.selectedParticle.y = pos.y
		event:hit()
	end
end

-- Hull Helper: Cross product of vectors OA and OB
local function cross(o: Particle, a: Particle, b: Particle)
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
end

-- Monotone Chain Algorithm for Convex Hull
local function getConvexHull(particles: {Particle}): {Particle}
    local n = #particles
    if n == 0 then return {} end
    if n <= 2 then return particles end

    local pts: {Particle} = {}
    for i = 1, n do pts[i] = particles[i] end

    table_sort(pts, function(a: Particle, b: Particle)
        return a.x < b.x or (a.x == b.x and a.y < b.y)
    end)

    local hull: {Particle} = {}
    -- Lower hull
    for i = 1, n do
        while #hull >= 2 and cross(hull[#hull-1], hull[#hull], pts[i]) <= 0 do
            table_remove(hull)
        end
        table_insert(hull, pts[i])
    end

    -- Upper hull
    local lowerLen = #hull
    for i = n-1, 1, -1 do
        while #hull > lowerLen and cross(hull[#hull-1], hull[#hull], pts[i]) <= 0 do
            table_remove(hull)
        end
        table_insert(hull, pts[i])
    end

    table_remove(hull)
    return hull
end

local function getSignedArea(hull: {Particle})
    local sum = 0
    local count = #hull
    for i = 1, count do
        local cur = hull[i]
        local nxt = hull[(i % count) + 1]
        sum = sum + (cur.x * nxt.y - nxt.x * cur.y)
    end
    return sum * 0.5
end

local function drawClusterOutlines(self: ParticleSystemNode, renderer: Renderer)
    if not DRAW_DEBUG_CLUSTERS then return end

    local parts = self._particles
    if not parts then return end
    
    local clusters = self._clusters or {}
    
    local path = self.clusterPath
    path:reset()
    
    for cid, cluster in ipairs(clusters) do
        if #cluster > 0 then
            local hull = getConvexHull(cluster)
            local count = #hull
            
            if count > 0 then
                -- 1. Ensure CW winding (Positive area in Y-down coordinates)
                local area = getSignedArea(hull)
                if area < 0 then
                    -- Reverse to make it CW
                    local rev: {Particle} = {}
                    for i = count, 1, -1 do table_insert(rev, hull[i]) end
                    hull = rev
                end
                
                -- 2. Trace Offset Hull
                for i = 1, count do
                    local curr = hull[i]
                    local nextP = hull[(i % count) + 1]
                    local prevP = hull[((i - 2 + count) % count) + 1]
                    
                    -- Vector to next
                    local dx = nextP.x - curr.x
                    local dy = nextP.y - curr.y
                    local len = msqrt(dx*dx + dy*dy)
                    if len < 0.001 then len = 1 end
                    
                    -- Normal pointing out (for CW hull in Y-down: (dy, -dx))
                    local nx = dy / len
                    local ny = -dx / len
                    
                    -- Vector from prev matches prev segment
                    local pdx = curr.x - prevP.x
                    local pdy = curr.y - prevP.y
                    local plen = msqrt(pdx*pdx + pdy*pdy)
                    if plen < 0.001 then plen = 1 end
                    
                    -- Normal of previous segment
                    local pnx = pdy / plen
                    local pny = -pdx / plen
                    
                    local r = curr.radius + self.outlineExpansion
                    
                    -- Start of arc at this vertex (end of incoming edge's offset)
                    local arcStart = Vector.xy(curr.x + pnx * r, curr.y + pny * r)
                    
                    -- End of arc at this vertex (start of outgoing edge's offset)
                    local arcEnd = Vector.xy(curr.x + nx * r, curr.y + ny * r)
                    
                    -- Angles for arc interpolation
                    local startAng = matan2(pny, pnx)
                    local endAng = matan2(ny, nx)
                    
                    -- Resolve angle wrapping
                    local diff = endAng - startAng
                    while diff <= -math.pi do diff = diff + 2*math.pi end
                    while diff > math.pi do diff = diff - 2*math.pi end
                    
                    if i == 1 then
                        path:moveTo(arcStart)
                    else
                        path:lineTo(arcStart)
                    end
                    
                    -- Approximate Arc with line segments
                    local steps = mfloor(mabs(diff) / 0.15) + 1
                    local step = diff / steps
                    for s = 1, steps do
                        local a = startAng + step * s
                        path:lineTo(Vector.xy(curr.x + mcos(a) * r, curr.y + msin(a) * r))
                    end
                end
                path:close()
            end
        end
    end
    
    if renderer then
        renderer:drawPath(path, self.clusterFillPaint)
        renderer:drawPath(path, self.clusterPaint)
    end
end

local function advance(self: ParticleSystemNode, seconds: number): boolean
	local dt = seconds
	if dt > 0.05 then dt = 0.05 end -- Cap dt

	-- 1. Emission Logic
	if self.packetIndex <= #self.packets then
		if self.packetDelayCounter > 0 then
			self.packetDelayCounter = self.packetDelayCounter - 1
		else
			-- Time to emit
			local currentPacket = self.packets[self.packetIndex]
			-- Check for end of packets to prevent nil access
			if currentPacket then
				if currentPacket.amount > 0 then
					spawnParticle(self, currentPacket)
					currentPacket.amount = currentPacket.amount - 1
					
					if currentPacket.amount > 0 then
						-- Next particle in same pack
						self.packetDelayCounter = mmax(1, mfloor(self.emissionInterval))
					else
						-- Pack finished, wait for next pack
						self.packetIndex = self.packetIndex + 1
						self.packetDelayCounter = mmax(1, mfloor(self.packetGap))
					end
				else
					-- Skip empty packs
					self.packetIndex = self.packetIndex + 1
					self.packetDelayCounter = 0
				end
			end
		end
	end

	local parts = self._particles
	-- Fast exit if no particles
	if not parts or #parts == 0 then return true end

	-- Cluster Intensity Ramp
	if self.activeClusterId then
		-- Ramp up over ~0.5 seconds
		self.clusterIntensity = mmin(1.0, self.clusterIntensity + dt * 2.0)
	else
		self.clusterIntensity = 0.0
	end

	-- 2. Interaction, Growth & Sleep Logic (Combined Loop)
	local sel = self.selectedParticle
	local iRadius = self.interactionRadius
	local growDur = self.growDuration
	
	-- Cache padding values for loop
	local rPad = self.relaxPadding
	local riPad = self.relaxInteractionPadding
	
	if growDur <= 0.01 then growDur = 0.01 end
	
	local changeSpeed = dt / growDur
	local px, py = self.pointerPos.x, self.pointerPos.y
	local count = #parts -- caching count
	local allSleeping = true
	-- SLEEP_VEL_SQ is now a constant

	for i = 1, count do
		local p = parts[i]
		
		-- A. Pointer Over Check
		if p.pointerOverProp then
			local dx = p.x - px
			local dy = p.y - py
			-- Check squared distance against squared radius
			local isOver = (dx*dx + dy*dy) <= (p.radius * p.radius)
			if p.pointerOverProp.value ~= isOver then
				p.pointerOverProp.value = isOver
			end
		end
		
		-- B. Growth Animation
		local targetT = 0.0
		if sel then
			if p == sel then
				targetT = 1.0
			else
				local dx = p.x - sel.x
				local dy = p.y - sel.y
				local distSq = dx*dx + dy*dy
				if distSq < iRadius * iRadius then
					local dist = msqrt(distSq)
					-- Linear falloff for target intensity
					targetT = 1.0 - (dist / iRadius)
				end
			end
		end

		if p.currentT < targetT then
			p.currentT = mmin(targetT, p.currentT + changeSpeed)
		elseif p.currentT > targetT then
			p.currentT = mmax(targetT, p.currentT - changeSpeed)
		end
		
		-- Apply Cubic Easing (Inlined)
		local t = p.currentT
		local easedT = t * t * (3 - 2 * t)
		p.easedT = easedT
		p.radius = p.originalRadius * (1 + 2 * easedT)
		p.relaxRadius = p.radius + rPad + riPad * easedT

		-- C. Sleep Update
		if not p.sleeping then
			local speedSq = p.vx * p.vx + p.vy * p.vy
			if speedSq < SLEEP_VEL_SQ then
				p.sleepTimer = p.sleepTimer + dt
				if p.sleepTimer > SLEEP_TIME_THRESH then
					p.sleeping = true
					p.vx = 0
					p.vy = 0
				end
			else
				p.sleepTimer = 0
			end
		end

		-- Track global sleep state
		if not p.sleeping then
			allSleeping = false
		end
		
		-- Advance instance animation (Merged loop optimization)
		p.instance:advance(dt)
	end
	
	-- Capture positions when everyone goes to sleep
	if allSleeping and not self.positionsCaptured then
		for i = 1, #parts do
			local p = parts[i]
			p.targetX = p.x
			p.targetY = p.y
		end
		self.positionsCaptured = true
	end

	-- If invalid state (e.g. new particles spawned), lose captured state
	if not allSleeping and self.positionsCaptured then
		-- Only reset if we are NOT interacting.
		-- Interaction (relax) moves particles but keeps 'sleeping' flag effectively by zeroing velocity.
		if self.selectedParticle == nil then
			self.positionsCaptured = false
		end
	end

	-- Force relax if interacting or all asleep (captured)
	local forceRelax = (self.selectedParticle ~= nil) or self.positionsCaptured

	if forceRelax then
		-- In relax mode: Just emit (if needed) and run relax solver
		-- We skip physics velocity integration to "switch off" physics
		relax(self, dt)
		
		-- Instance advancement is now done in the main loop above
	end

	-- 3. Physics Update (PBD)
	
	if not forceRelax then
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
		
		-- Optimization: Build grid ONCE per frame
		-- Used for particle-particle collision (broadphase)
		local grid = buildGrid(self, parts, CELL_SIZE)

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

			-- B. Constraint Solving - Particle & Walls
			for i = 1, pCount do
				local p = parts[i]
				
				-- Cache for inner loop
				local pid = p.id
				local px = p.x
				local py = p.y
				local prad = p.radius
				
				-- Particle-Particle (Using frame-start broadphase grid)
				local cx = mfloor(px / CELL_SIZE)
				local cy = mfloor(py / CELL_SIZE)
				local baseKey = cx * GRID_P1 + cy * GRID_P2
				
				for k = 1, 9 do
					local nKey = baseKey + GRID_OFFSETS[k]
					local cell = grid[nKey]
					if cell then
						for j = 1, #cell do
							local other = cell[j]
							if other.id > pid then
								local dx = other.x - px
								local dy = other.y - py
								local distSq = dx*dx + dy*dy
								local radSum = prad + other.radius
								
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
	end
	
	-- 4. Update Graphics (Removed: Logic merged into main loop)

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
	local ew = self.emitterWidth / 2
	local ey = self.emitterY
	self.emitterPath:moveTo(Vector.xy(-ew, ey))
	self.emitterPath:lineTo(Vector.xy(ew, ey))
	renderer:drawPath(self.emitterPath, self.emitterPaint)

	drawClusterOutlines(self, renderer)

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
		emitterWidth = 500,
		emitterY = -400,
		emissionInterval = 5,     -- Slower emission
		packetGap = 15,           -- Gap between packs
		initialVelocityY = 0,
		growDuration = 1.0,
		interactionRadius = 200.0,
		relaxPadding = 0.0,
		relaxInteractionPadding = 20.0,
		
		outlineExpansion = 15.0,
		
		globalClusterStrength = 0.5,
		activeClusterStrength = 5.0,

		boxWidth = 150,
		boxHeight = 700,
		boxY = 200,
		
		boxPath = Path.new(),
		emitterPath = Path.new(),
		boxPaint = Paint.new(),
		emitterPaint = Paint.new(),
		clusterPath = Path.new(),
		clusterPaint = Paint.new(),
		clusterFillPaint = Paint.new(),
		lastSpawnX = nil,
		spawnDirection = 0,

		_particles = {},
		_clusters = {}, -- Added
		packets = {},
		packetIndex = 1,
		packetDelayCounter = 0,
		frameCounter = 0,
		mat = Mat2D.identity(),
		grid = {}, -- Kept for legacy struct matching if needed, though unused logic-wise
		gridKeys = {}, -- Added for optimization
		artboards = {}, -- Cached inputs array

		nextId = 1,

		positionsCaptured = false,
		selectedParticle = nil,
		activeClusterId = nil,
		clusterIntensity = 0.0,
		pointerPos = {x=0, y=0},
		
		init = init,
		advance = advance,
		draw = draw,
		pointerDown = pointerDown,
		pointerUp = pointerUp,
		pointerMove = pointerMove,
	}
end

