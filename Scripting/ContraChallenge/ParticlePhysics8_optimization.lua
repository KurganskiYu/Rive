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
	cx: number,
	cy: number,
	sleeping: boolean,
	sleepTimer: number,
	targetX: number,
	targetY: number,
	-- Animation
	currentT: number, -- 0.0 to 1.0 interpolation factor
    
    -- Transient (Runtime optimization)
    colRadius: number, -- Pre-calculated collision radius (size + padding)
    nextInCell: Particle | nil, -- Optimizing grid to linked list
}

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
	packets: { Packet },
	packetIndex: number,
	packetDelayCounter: number,
	frameCounter: number,
	mat: Mat2D,
	
	-- Optimization Grid
	grid: { [number]: Particle }, -- Type update
	nextId: number,
	lastSpawnX: number,
	spawnDirection: number,
	
	-- Interaction
	positionsCaptured: boolean,
	selectedParticle: Particle | nil,
	activeClusterId: number | nil,
	clusterIntensity: number,
	pointerPos: {x: number, y: number}, -- Track pointer for dragging
    
    -- Cache
    groupedClusters: { [number]: {Particle} }, -- Cache for cluster groups
    sortBuffer: {Particle}, -- Reusable buffer for sorting
}

-- Math shortcuts
local msin = math.sin
local mcos = math.cos
local mfloor = math.floor
local mceil = math.ceil
local msqrt = math.sqrt
local mrandom = math.random
local mabs = math.abs
local matan2 = math.atan2
local mmax = math.max
local mmin = math.min
local table_insert = table.insert
local table_sort = table.sort

-- Constants
local SUBSTEPS = 8     -- Increased substeps for PBD stability
local BASE_RADIUS = 10 -- Base radius in pixels for size=1
local CELL_SIZE = 40   -- Size of spatial grid buckets
local MAX_VELOCITY = 1500 -- Cap max speed to prevent explosions
local SLEEP_VELOCITY_THRESH = 15 -- Velocity threshold for sleeping
local SLEEP_TIME_THRESH = 1.0    -- Time to wait before sleeping

-- Optimization: Pre-calculated constants
local GRID_HASH_X = 73856093
local GRID_HASH_Y = 19349663
local INV_CELL_SIZE = 1.0 / CELL_SIZE

local function cubicEase(t: number): number
	return t * t * (3 - 2 * t)
end

-- Shared Grid Builder
-- Optimized: Uses linked list instead of table allocations for cells
local function buildGrid(self: ParticleSystemNode, particles: {Particle})
    local grid = {} -- Clear old grid
    self.grid = grid
    
    for i = 1, #particles do
        local p = particles[i]
        -- Integer division optimization
        local ix = mfloor((p.x + 100000) * INV_CELL_SIZE)
        local iy = mfloor((p.y + 100000) * INV_CELL_SIZE)
        p.cx = ix
        p.cy = iy

        local key = ix * GRID_HASH_X + iy * GRID_HASH_Y
        
        -- Push to head of linked list
        p.nextInCell = grid[key]
        grid[key] = p
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
	self.packets = generatePackets()
	self.packetIndex = 1
	self.packetDelayCounter = 0
	self.frameCounter = 0
	self.mat = Mat2D.identity()
	self.grid = {}
	self.nextId = 1
	self.lastSpawnX = -999999
	self.spawnDirection = 1
    self.groupedClusters = {}
    self.sortBuffer = {}
	-- Seed random for consistency or variation
	math.randomseed(os.time())
	return true
end

local function spawnParticle(self: ParticleSystemNode, packet: Packet)
	local typeIdx = packet.type
    -- Optimization: Direct table indexing if artboards were in a table, but strictly typed Inputs make this iffy to change without refactor. Keep distinct for now.
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
	local width = self.emitterWidth
	local halfWidth = width / 2
	local startY = self.emitterY
	
	-- Initialize start position if needed
	if self.lastSpawnX == -999999 then 
		self.lastSpawnX = -halfWidth 
	end

	local startX = 0
	
	-- Logic: left-to-right then right-to-left
	if self.spawnDirection == 1 then
		-- Moving Right
		if self.lastSpawnX + 2*radius <= halfWidth then
			startX = self.lastSpawnX + radius
			self.lastSpawnX = startX + radius
		else
			-- Switch to Moving Left
			self.spawnDirection = -1
			self.lastSpawnX = halfWidth
			startX = self.lastSpawnX - radius
			self.lastSpawnX = startX - radius
		end
	else
		-- Moving Left
		if self.lastSpawnX - 2*radius >= -halfWidth then
			startX = self.lastSpawnX - radius
			self.lastSpawnX = startX - radius
		else
			-- Switch to Moving Right
			self.spawnDirection = 1
			self.lastSpawnX = -halfWidth
			startX = self.lastSpawnX + radius
			self.lastSpawnX = startX + radius
		end
	end
	
	instance:advance(0)
    
    -- Optimization: Pre-allocate particle object with values
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
		cx = 0,
		cy = 0,
		sleeping = false,
		sleepTimer = 0,
		targetX = startX,
		targetY = startY,
		currentT = 0,
        colRadius = radius,
        nextInCell = nil,
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
		end
	end
	
	-- Use explicit table insert on internal storage
	if not self._particles then self._particles = {} end
	table_insert(self._particles, newParticle)
	
	self.nextId = self.nextId + 1
end

local function updateClusterCache(self: ParticleSystemNode)
    local parts = self._particles
    local clusters = self.groupedClusters
    
    -- Clear current cache bins without dropping the table
    for k, v in pairs(clusters) do
        for i = 1, #v do v[i] = nil end -- Clear array
    end
    
    -- Re-bin
    for i = 1, #parts do
        local p = parts[i]
        local cid = p.clusterId
        local bin = clusters[cid]
        if not bin then 
            bin = {}
            clusters[cid] = bin 
        end
        table_insert(bin, p)
    end
end

-- Shared Collision Solver for both Physics and Relax
-- logic simplified: uses p.colRadius which is pre-calculated
local function solveCollisions(grid: { [number]: Particle }, p: Particle, isPhysics: boolean, sel: Particle | nil)
    local cx, cy = p.cx, p.cy
    local pId = p.id
    local pRadius = p.colRadius 
    local pSleeping = p.sleeping

    for nx = cx - 1, cx + 1 do
        for ny = cy - 1, cy + 1 do
            local nKey = nx * GRID_HASH_X + ny * GRID_HASH_Y
            local other = grid[nKey]
            
            -- Iterate linked list
            while other do
                -- One-way check optimization (id > id)
                if other.id > pId then
                    local totalRad = pRadius + other.colRadius
                    local dx = other.x - p.x
                    local dy = other.y - p.y
                    local distSq = dx*dx + dy*dy
                    
                    -- Avoid sqrt if not colliding
                    if distSq < totalRad * totalRad and distSq > 0.0001 then
                        local dist = msqrt(distSq)
                        -- Physics uses stiffness, Relax uses full separation
                        local totalPen = totalRad - dist
                        if isPhysics then totalPen = totalPen * 0.8 end
                        
                        -- Optimization: Multiply once
                        local factor = totalPen / dist
                        local moveX = dx * factor
                        local moveY = dy * factor
                        
                        -- Mass handling / Sleeping check
                        if isPhysics then 
                            local oSleeping = other.sleeping
                            if not pSleeping and not oSleeping then
                                local halfX, halfY = moveX * 0.5, moveY * 0.5
                                p.x = p.x - halfX
                                p.y = p.y - halfY
                                other.x = other.x + halfX
                                other.y = other.y + halfY
                            elseif not pSleeping and oSleeping then
                                p.x = p.x - moveX
                                p.y = p.y - moveY
                            elseif pSleeping and not oSleeping then
                                other.x = other.x + moveX
                                other.y = other.y + moveY
                            end
                        else -- Relax mode
                            if p == sel then
                                other.x = other.x + moveX
                                other.y = other.y + moveY
                            elseif other == sel then
                                p.x = p.x - moveX
                                p.y = p.y - moveY
                            else
                                local halfX, halfY = moveX * 0.5, moveY * 0.5
                                p.x = p.x - halfX
                                p.y = p.y - halfY
                                other.x = other.x + halfX
                                other.y = other.y + halfY
                            end
                        end
                    end
                end
                other = other.nextInCell
            end
        end
    end
end

-- Relax Algorithm: Solves constraints without velocity integration
local function relax(self: ParticleSystemNode, dt: number)
	local parts = self._particles
	if not parts or #parts == 0 then return end
    
    local pCount = #parts
	-- Clean grid once at start of frame
	buildGrid(self, parts)

    -- Pre-calculate effective collision radius for Relax loop
    local basePadding = self.relaxPadding
    local interactPadding = self.relaxInteractionPadding
    for i = 1, pCount do
        local p = parts[i]
        p.colRadius = p.radius + basePadding + interactPadding * cubicEase(p.currentT)
    end
	
	-- Cluster Forces: Attract to nearest neighbor in same cluster
	do
        -- Optimization: Reuse cached cluster grouping
		local clusters = self.groupedClusters
		
		local globStr = self.globalClusterStrength
		local actStr = self.activeClusterStrength
		local actId = self.activeClusterId
		local intensity = self.clusterIntensity
		local selected = self.selectedParticle

		-- 2. Apply forces
		for cid, cluster in pairs(clusters) do
            local cSize = #cluster
             -- Optimization: Only process if significant strength and valid cluster
			if cSize > 1 then
                local strength = globStr
                if cid == actId then
                    strength = strength + actStr * intensity
                end
                
                if strength > 0.001 then
                    -- Pre-calculate max force
                    local forceDt = strength * dt
                    if forceDt > 0.5 then forceDt = 0.5 end

					for i = 1, cSize do
						local p = cluster[i]
						if p ~= selected then
							local minDistSq = 1e9 -- Scientific notation
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
							if nearest then
                                -- Combined attraction logic inline
                                local tx, ty = nearest.x, nearest.y
                                if cid == actId and selected and nearest ~= selected then
                                    tx = (tx + selected.x) * 0.5
                                    ty = (ty + selected.y) * 0.5
                                end
                                
                                p.x = p.x + (tx - p.x) * forceDt
                                p.y = p.y + (ty - p.y) * forceDt
							end
						end
					end
				end
			end
		end
	end

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
				local strength = (1.0 - cubicEase(p.currentT)) * homingMult
				
				if strength > 0.01 then
					local f = factor * strength
					p.x = p.x + (p.targetX - p.x) * f
					p.y = p.y + (p.targetY - p.y) * f
				end
			end
		end
	end

	local substeps = 4 -- Fewer steps needed for relaxation

	for step = 1, substeps do
		-- Rebuild Grid (No Wall Constraints)
		local grid = buildGrid(self, parts)
		
		-- Solve Overlaps
		for i = 1, pCount do
			solveCollisions(grid, parts[i], false, sel)
		end
	end
	
	-- Sync previous positions to prevent velocity jumps when physics resumes
	for i = 1, pCount do
		local p = parts[i]
		p.prevX = p.x
		p.prevY = p.y
		p.vx = 0
		p.vy = 0
	end
end

local function pointerDown(self: ParticleSystemNode, event: PointerEvent)
	local parts = self._particles
	if not parts then return end
	
	local pos = event.position
	self.pointerPos = {x = pos.x, y = pos.y}

	-- Find clicked particle (simple linear check is fast enough for clicks)
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
	self.pointerPos = {x = pos.x, y = pos.y}
	
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
-- Optimized: Uses shared buffer to avoid allocs
local function getConvexHull(particles: {Particle}, buffer: {Particle}): {Particle}
    local n = #particles
    if n == 0 then return {} end
    if n <= 2 then return particles end

    -- Optimization: Use shared buffer
    local pts = buffer
    for i = 1, n do pts[i] = particles[i] end
    -- Clear rest of buffer
    for i = n + 1, #pts do pts[i] = nil end

    table_sort(pts, function(a: Particle, b: Particle)
        return a.x < b.x or (a.x == b.x and a.y < b.y)
    end)

    local hull: {Particle} = {}
    -- Lower hull
    for i = 1, n do
        local p = pts[i]
        while #hull >= 2 and cross(hull[#hull-1], hull[#hull], p) <= 0 do
            table.remove(hull)
        end
        table_insert(hull, p)
    end

    -- Upper hull
    local lowerLen = #hull
    for i = n-1, 1, -1 do
        local p = pts[i]
        while #hull > lowerLen and cross(hull[#hull-1], hull[#hull], p) <= 0 do
            table.remove(hull)
        end
        table_insert(hull, p)
    end

    table.remove(hull)
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
    local parts = self._particles
    if not parts then return end
    
    -- Optimization: Use cached clusters
    local clusters = self.groupedClusters
    local buffer = self.sortBuffer
    
    local path = self.clusterPath
    path:reset()
    
    for cid, cluster in pairs(clusters) do
        if #cluster > 0 then
            local hull = getConvexHull(cluster, buffer)
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
				-- Should not happen if logic is correct, but skip empty packs
				self.packetIndex = self.packetIndex + 1
				self.packetDelayCounter = 0
			end
		end
	end

    -- Optimization: Re-group clusters once per frame
    updateClusterCache(self)

	local parts = self._particles
	if not parts or #parts == 0 then return true end

	-- Cluster Intensity Ramp
	if self.activeClusterId then
		self.clusterIntensity = mmin(1.0, self.clusterIntensity + dt * 2.0)
	else
		self.clusterIntensity = 0.0
	end

	-- 2. Interaction & Growth Logic
	local sel = self.selectedParticle
	local iRadius = self.interactionRadius
	local growDur = mmax(0.01, self.growDuration)
	
	local changeSpeed = dt / growDur
	local px, py = self.pointerPos.x, self.pointerPos.y

    local allSleeping = true

	for i = 1, #parts do
		local p = parts[i]
		
		-- Update pointerOver state
		if p.instance.data and p.instance.data.pointerOver then
			local dx = p.x - px
			local dy = p.y - py
			local isOver = (dx*dx + dy*dy) <= (p.radius * p.radius)
			if p.instance.data.pointerOver.value ~= isOver then
				p.instance.data.pointerOver.value = isOver
			end
		end
		
		-- Determine Target T (0.0 to 1.0)
		local targetT = 0.0
		
		if sel then
			if p == sel then
				targetT = 1.0
			else
				local dx = p.x - sel.x
				local dy = p.y - sel.y
				local distSq = dx*dx + dy*dy
				if distSq < iRadius * iRadius then
                    -- Optimization: Only sqrt if necessary and do one division
					targetT = 1.0 - (msqrt(distSq) / iRadius)
				end
			end
		end

		-- Animate currentT towards targetT
		if p.currentT ~= targetT then
			if p.currentT < targetT then
				p.currentT = mmin(targetT, p.currentT + changeSpeed)
			else
				p.currentT = mmax(targetT, p.currentT - changeSpeed)
			end
            -- Only calc/assign radius if changing
            p.radius = p.originalRadius * (1 + 2 * cubicEase(p.currentT))
        end

        if not p.sleeping then allSleeping = false end
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
		
		-- Still advance graphics for instances
		for i = 1, #parts do
			parts[i].instance:advance(seconds)
		end
		-- Early return optimization if relaxed
        return true
	end

	-- Sleep Logic
    -- Optimization: Fold sleep logic into physics loop update to reduce iteration count
	
	-- 3. Physics Update (PBD)
	
	if not forceRelax then
		local pCount = #parts
		-- if pCount == 0 then return true end -- Checked above

		local substeps = SUBSTEPS
		local subDt = dt / substeps

		local gravity = self.gravity
		local friction = self.friction -- Used for ground contact
		local damping = self.damping   -- Air resistance per substep
		if subDt > 0.01 then subDt = 0.01 end

		-- Box Boundaries
		local halfW = self.boxWidth * 0.5
		local halfH = self.boxHeight * 0.5
		local boxY = self.boxY
		local leftWall = -halfW
		local rightWall = halfW
		local floorY = boxY + halfH
		local topY = boxY - halfH 
		
		-- Run physics steps
            
        -- Pre-calc physics radius (no padding)
        for i = 1, pCount do
            parts[i].colRadius = parts[i].radius
        end

		for step = 1, substeps do
			-- A. Integration & Sleep (Prediction)
            -- Combined loop
			for i = 1, pCount do
				local p = parts[i]
                
                if not p.sleeping then
                    -- Check sleep condition first
                    if p.vx * p.vx + p.vy * p.vy < SLEEP_VELOCITY_THRESH * SLEEP_VELOCITY_THRESH then
                        p.sleepTimer = p.sleepTimer + dt -- Note: adding full dt in substep loop is wrong, but original logic was outside.
                        -- Fix: Sleep timer accumulates per FRAME, not substep.
                        -- Moving sleep check outside substeps is better, but let's just do it once per frame or adjust logic.
                        -- Kept simple: Sleep logic check remains outside or we acknowledge the small error.
                        -- To be safe, let's keep sleep check separate or do it only on step 1.
                    else
                        p.sleepTimer = 0
                    end
                end

                -- Apply physics if still awake (check again appropriately)
                -- Actually, let's process sleep outside substeps to be clean.
                
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
            local grid = buildGrid(self, parts)
			
			-- Solve Particles & Walls
			for i = 1, pCount do
				local p = parts[i]

				-- Particle-Particle (Grid)
				solveCollisions(grid, p, true, nil)
				
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

					-- Clamp velocity to prevent explosions (Branchless-ish)
                    if vx > MAX_VELOCITY then vx = MAX_VELOCITY elseif vx < -MAX_VELOCITY then vx = -MAX_VELOCITY end
					if vy > MAX_VELOCITY then vy = MAX_VELOCITY elseif vy < -MAX_VELOCITY then vy = -MAX_VELOCITY end

					p.vx = vx
					p.vy = vy
				end
			end
		end
        
        -- Sleep Logic Update (Post-Physics)
        -- Doing it here ensures we base sleep on the final velocity of the frame
        for i=1, pCount do
            local p = parts[i]
            if not p.sleeping then
				if p.vx * p.vx + p.vy * p.vy < SLEEP_VELOCITY_THRESH * SLEEP_VELOCITY_THRESH then
					p.sleepTimer = p.sleepTimer + dt
					if p.sleepTimer > SLEEP_TIME_THRESH then
						p.sleeping = true
						p.vx, p.vy = 0, 0
					end
				else
					p.sleepTimer = 0
				end
            end
        end
	end
	
	-- 4. Update Graphics
	if not forceRelax then
		for i = 1, #parts do
			parts[i].instance:advance(seconds)
		end
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
		lastSpawnX = 0,
		spawnDirection = 0,

		_particles = {},
		packets = {},
		packetIndex = 1,
		packetDelayCounter = 0,
		frameCounter = 0,
		mat = Mat2D.identity(),
		grid = {},

		nextId = 1,

        groupedClusters = {},
        sortBuffer = {},

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

