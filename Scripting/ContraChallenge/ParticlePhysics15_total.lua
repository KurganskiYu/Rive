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
--
-- STRICT TYPE ENFORCEMENT: 
-- 1. Struct Constructors: When creating a table typed as a class (e.g. `local p: Particle = {...}`), 
--    you MUST initialize ALL fields defined in the type definition. Missing fields cause errors.
-- 2. Sort Comparators: Anonymous functions in `table.sort` require explicit argument types 
--    (e.g. `function(a: Particle, b: Particle)`).
-- 3. Factory Return: The table returned by the main factory function MUST contain initialized values 
--    (or `late()`) for EVERY field defined in the script's main Type definition.
----------------------------------

-- Type definitions
type ParticleVM = {
	time: Property<string>,
	bpm: Property<any>, -- Changed to any to support range string "60-120"
	type: Property<number>,
	active: Property<boolean>,
	pointerOver: Property<boolean>,
}

type InfoVM = {
	time: Property<string>
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
    
    -- Stats Layout
    statsX: number,
    statsY: number,

    -- Transient (Runtime optimization)
    colRadius: number, -- Pre-calculated collision radius (size + padding)
    nextInCell: Particle | nil, -- Optimizing grid to linked list

	-- Group Point specific
	birthTime: number,
	birthBpm: number,
	isGroupPoint: boolean,
    type: number, -- Explicitly store type for grouping logic
    
    -- Interaction Animation
    expanded: boolean,
    animT: number, -- 0.0 to 1.0 for position animation
    animDelay: number,
}

type TimeMarker = {
	x: number,
	y: number,
	instance: Artboard<InfoVM>
}

type PendingTimeMarker = {
    x: number,
    y: number,
    hour: number
}

type ClusterStat = {
	cid: number, -- Added Cluster ID
	sumX: number,
	sumY: number,
	n: number,
	minTime: number,
	maxTime: number,
	minBpm: number,
	maxBpm: number,
	type: number,
	calculatedRadius: number -- Store pre-calculated radius
}

type Packet = {
	type: number,
	amount: number,
	size: number,
    clusterId: number -- Added to group consecutive packets of same type
}

type ParticleSystemNode = {
	-- Inputs
	artboard1: Input<Artboard<ParticleVM>>,
	artboard2: Input<Artboard<ParticleVM>>,
	artboard3: Input<Artboard<ParticleVM>>,
	artboard4: Input<Artboard<ParticleVM>>,
	artboard5: Input<Artboard<ParticleVM>>,
	artboardGroup: Input<Artboard<ParticleVM>>, -- New input for group points
	artboardTime: Input<Artboard<InfoVM>>, -- New input for time markers
	activate: Input<Trigger>, -- Renamed from start to avoid keyword conflicts

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
	
	groupPointX: Input<number>,
	
	globalClusterStrength: Input<number>,
	activeClusterStrength: Input<number>,

    -- Stats Inputs
    stats: Input<boolean>,
    statsStartX: Input<number>,
    statsStartY: Input<number>,
    statsGapX: Input<number>,
    statsScaleY: Input<number>,

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
	timeMinutes: number, -- For sequential time generation
	mat: Mat2D,
	
    -- Time Markers
	timeMarkers: { TimeMarker },
    pendingTimeMarkers: { PendingTimeMarker },
    timeMarkerSpawnTimer: number,

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
    
    groupPointsCreated: boolean, -- Flag to only spawn group points once (prep phase)
	groupPointShiftX: number,
    
    statsCalculated: boolean,

    started: boolean, -- New state to track system activation

    -- Cache
    groupedClusters: { [number]: {Particle} }, -- Cache for cluster groups

    -- Spawning Queue
    pendingGroupClusters: { ClusterStat },
    groupSpawnTimer: number,
}

-- Math shortcuts
local mfloor = math.floor
local msqrt = math.sqrt
local mrandom = math.random
local mmax = math.max
local mmin = math.min
local table_insert = table.insert

-- Constants
local SUBSTEPS = 8     -- Increased substeps for PBD stability
local BASE_RADIUS = 10 -- Base radius in pixels for size=1
local CELL_SIZE = 40   -- Size of spatial grid buckets
local MAX_VELOCITY = 1500 -- Cap max speed to prevent explosions
local SLEEP_VELOCITY_THRESH = 15 -- Velocity threshold for sleeping
local SLEEP_TIME_THRESH = 1.0    -- Time to wait before sleeping
local TOTAL_PARTICLES = 500      -- Explicit target for particle count

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
	local np = TOTAL_PARTICLES
	local totalParticles = 0
    local clusterIdCounter = 0
    local lastType = -1

	while totalParticles < np do
		local amount = mrandom(5, 28)
		if totalParticles + amount > np then
			amount = np - totalParticles
		end
        
        local t = mrandom(1, 5)
        if t ~= lastType then
            clusterIdCounter = clusterIdCounter + 1
            lastType = t
        end

		table_insert(packs, {
			type = t,      			-- Artboard type 1-5
			amount = amount,   			-- Adjusted to reach total of 600 particles
			size = 1.0 + (mrandom(0, 6) * 0.1),  -- Scale factor
            clusterId = clusterIdCounter
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

	self._particles = {}
	self.packets = generatePackets()
	self.packetIndex = 1
	self.packetDelayCounter = 0
	self.timeMinutes = 8 * 60 + 10 -- Start at 8:10
	self.mat = Mat2D.identity()
	self.grid = {}
	self.timeMarkers = {}
    self.pendingTimeMarkers = {}
    self.timeMarkerSpawnTimer = 0
	self.nextId = 1
	self.started = false
	self.groupPointsCreated = false
    self.statsCalculated = false
	self.lastSpawnX = -999999
	self.spawnDirection = 1
    self.groupedClusters = {}
    
    self.pendingGroupClusters = {}
    self.groupSpawnTimer = 0

	-- Seed random for consistency or variation
	math.randomseed(os.time())
	return true
end

-- Trigger callback to start the system
local function activate(self: ParticleSystemNode)
	self.started = true
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
	
    -- Determine BPM and Size calculation FIRST so radius is known
    local minB, maxB = 60, 170
    if packet.type == 1 then minB, maxB = 52, 62
    elseif packet.type == 2 then minB, maxB = 62, 70
    elseif packet.type == 3 then minB, maxB = 70, 85
    elseif packet.type == 4 then minB, maxB = 85, 120
    elseif packet.type == 5 then minB, maxB = 120, 170
    end

    local bpmVal = mrandom(minB, maxB)
    
    -- Calculate normalized factor (0.0 to 1.0)
    local t = 0
    if maxB > minB then
        t = (bpmVal - minB) / (maxB - minB)
    end

    -- Size scaling: 1.0 (min BPM) to 1.6 (max BPM)
    -- Replacing packet.size with BPM-dependent logic
    local sizeScale = 1.0 + (t * 0.6)

	local radius = BASE_RADIUS * sizeScale * self.sizeMultiplier
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
		clusterId = packet.clusterId, -- Use combined cluster ID from packet
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
        statsX = 0,
        statsY = 0,
		birthTime = self.timeMinutes,
		birthBpm = bpmVal, -- Use pre-calculated BPM
		isGroupPoint = false,
        type = packet.type, -- Store type explicitly
        expanded = false,
        animT = 0,
        animDelay = 0,
	}
	
	-- Initialize ViewModel state
	if instance.data then
		if instance.data.time then
			local totalMins = self.timeMinutes
			self.timeMinutes = totalMins + 1
			
			local h = mfloor(totalMins / 60)
			local m = totalMins % 60
			-- 24-hour format
			local displayH = h % 24
			
			instance.data.time.value = string.format("%02d:%02d", displayH, m)
		end
		
		if instance.data.bpm then
			instance.data.bpm.value = bpmVal
		end
		
		if instance.data.type then
			instance.data.type.value = packet.type
		end
		
		if instance.data.active then
			instance.data.active.value = false
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
                            local pStatic = (p == sel) or p.isGroupPoint
                            local oStatic = (other == sel) or other.isGroupPoint

                            if pStatic and not oStatic then
                                other.x = other.x + moveX
                                other.y = other.y + moveY
                            elseif oStatic and not pStatic then
                                p.x = p.x - moveX
                                p.y = p.y - moveY
                            elseif not pStatic and not oStatic then
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

    local useStats = self.stats

    -- Pre-calculate effective collision radius for Relax loop
    local basePadding = self.relaxPadding
    local interactPadding = self.relaxInteractionPadding
    for i = 1, pCount do
        local p = parts[i]
        if useStats and p.isGroupPoint then
             p.colRadius = 0
        else
             p.colRadius = p.radius + basePadding + interactPadding * cubicEase(p.currentT)
        end
    end
	
	-- Cluster Forces: Attract to nearest neighbor in same cluster
    -- Disable clustering effects when in Stats mode to keep lines straight
	if not useStats then
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
						if p ~= selected and not p.isGroupPoint then
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
			if p ~= sel and not p.isGroupPoint then
				-- Calculate effective cluster strength to reduce jittery conflict
				local cStr = globStr
				if p.clusterId == actId then
					cStr = cStr + actStr * intensity
				end
				
				-- In stats mode, ignore cluster strength so homing is full power
				if useStats then cStr = 0 end
						
				-- Proportionally decrease position force when clustering force increases
				-- If strength >= 1, homing is 0.
				local homingMult = 1.0 - cStr
				if homingMult < 0 then homingMult = 0 end

				-- Jitter fix: Reduce homing force if particle is interacting/growing
				local strength = (1.0 - cubicEase(p.currentT)) * homingMult
						
				if strength > 0.01 then
					local f = factor * strength
                    local tx, ty = p.targetX, p.targetY

                    if useStats then
                        tx = p.statsX
                        ty = p.statsY
                    end

					p.x = p.x + (tx - p.x) * f
					p.y = p.y + (ty - p.y) * f
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
			
			if p.isGroupPoint then
				-- Group Point Toggle Logic
                p.expanded = not p.expanded
                p.animDelay = 30

				if p.instance.data and p.instance.data.active then
					p.instance.data.active.value = p.expanded
				end

				-- Delayed selection logic moved to advance() to sync with movement
			else
				-- Normal Particle Logic
				self.selectedParticle = p
				self.activeClusterId = p.clusterId
				self.clusterIntensity = 0.0 
			end
			
			event:hit() -- Consume event
			return
		end
	end
end

local function pointerUp(self: ParticleSystemNode, event: PointerEvent)
	if self.selectedParticle then
		-- Only clear if it's NOT a group point (drag-lock for group points)
		if not self.selectedParticle.isGroupPoint then
			self.selectedParticle = nil
			self.activeClusterId = nil
		end
	end
end

local function pointerMove(self: ParticleSystemNode, event: PointerEvent)
	local pos = event.position
	self.pointerPos = {x = pos.x, y = pos.y}
	
	if self.selectedParticle then
		-- Only move if regular particle. Group points should NOT stick to pointer.
		if not self.selectedParticle.isGroupPoint then
			self.selectedParticle.x = pos.x
			self.selectedParticle.y = pos.y
		end
		event:hit()
	end
end
 
-- Helper to spawn a single group point from pre-calculated data
local function spawnSingleGroupPoint(self: ParticleSystemNode, c: ClusterStat)
    local gpX = self.groupPointX
    local gpY = c.sumY / c.n
    local radius = c.calculatedRadius
    
    local inputAb = self.artboardGroup
    
    local instance = inputAb:instance()
    if instance then
        instance:advance(0)
        
        -- Format Data Ranges
        if instance.data then
            if instance.data.time then
                local function fmtT(m: number)
                    local h = mfloor(m / 60)
                    local dispH = h % 24
                    return string.format("%02d:%02d", dispH, m % 60)
                end
                instance.data.time.value = fmtT(c.minTime) .. "-" .. fmtT(c.maxTime)
            end
            if instance.data.bpm then
                instance.data.bpm.value = string.format("%d-%d", mfloor(c.minBpm), mfloor(c.maxBpm))
            end
            if instance.data.type then
                instance.data.type.value = c.type
            end
            if instance.data.active then
                instance.data.active.value = false
            end
        end
        
        local gp: Particle = {
            id = self.nextId,
            clusterId = c.cid,
            x = gpX, y = gpY,
            prevX = gpX, prevY = gpY,
            vx = 0, vy = 0,
            radius = radius,
            originalRadius = radius,
            instance = instance,
            cx = 0, cy = 0,
            sleeping = true,
            sleepTimer = 0,
            targetX = gpX, targetY = gpY,
            currentT = 0,
            colRadius = radius,
            nextInCell = nil,
            statsX = 0,
            statsY = 0,
            birthTime = 0,
            birthBpm = 0,
            isGroupPoint = true,
            type = c.type, -- Store type explicitly
            expanded = false,
            animT = 0,
            animDelay = 0,
        }
        
        self.nextId = self.nextId + 1
        table_insert(self._particles, gp)
    end
end

-- Prepares the queue of group points to be spawned
local function prepareGroupPointsQueue(self: ParticleSystemNode)
	if self.groupPointsCreated then return end
	self.groupPointsCreated = true

	local parts = self._particles
	local count = #parts
	local clusterMap: { [number]: ClusterStat } = {}
    local existingGPs: { [number]: boolean } = {}
    
    local globalMinN = 999999
    local globalMaxN = 0

	-- 1. Gather stats per cluster
	for i = 1, count do
		local p = parts[i]
        
        if p.isGroupPoint then
            existingGPs[p.clusterId] = true
        else
			local cid = p.clusterId
			local c = clusterMap[cid]
			if not c then
				c = {
                    cid = cid,
					sumX = 0, sumY = 0, n = 0,
					minTime = 999999, maxTime = -1,
					minBpm = 999999, maxBpm = -1,
					type = p.type, -- Reliable type from particle
                    calculatedRadius = BASE_RADIUS
				}
				clusterMap[cid] = c
			end
			c.sumX = c.sumX + p.x
			c.sumY = c.sumY + p.y
			c.n = c.n + 1
			if p.birthTime < c.minTime then c.minTime = p.birthTime end
			if p.birthTime > c.maxTime then c.maxTime = p.birthTime end
			if p.birthBpm < c.minBpm then c.minBpm = p.birthBpm end
			if p.birthBpm > c.maxBpm then c.maxBpm = p.birthBpm end
		end
	end

    -- Find range for normalization
    for _, c in pairs(clusterMap) do
        if c.n < globalMinN then globalMinN = c.n end
        if c.n > globalMaxN then globalMaxN = c.n end
    end
    if globalMaxN <= globalMinN then globalMaxN = globalMinN + 1 end

	-- 2. Fill Queue (Sorted by ID ensures consistent order)
    -- We can iterate pairs, but sorting logic if needed. Pairs is fine for now.
	for cid, c in pairs(clusterMap) do
		if c.n > 11 and not existingGPs[cid] then
			-- Calculate radius once and store it
			local t = (c.n - globalMinN) / (globalMaxN - globalMinN)
			-- local scale = (1.2 + t) * self.sizeMultiplier -- keep it for later use
			local scale = 1.3 * self.sizeMultiplier
			c.calculatedRadius = BASE_RADIUS * scale
            
            table_insert(self.pendingGroupClusters, c)
		end
	end
end
 
local function calculateStatsPositions(self: ParticleSystemNode)
    if self.statsCalculated then return end

    local parts = self._particles
    local byType: { [number]: {Particle} } = {}
    
    -- 1. Bin particles by type
    for i = 1, #parts do
        local p = parts[i]
        if not p.isGroupPoint then
            local t = p.type
            local list = byType[t]
            if not list then 
                list = {}
                byType[t] = list
            end
            table_insert(list, p)
        end
    end
    
    -- 2. Sort and Layout
    local startX = self.statsStartX
    local startY = self.statsStartY
    local gapX = self.statsGapX
    local scaleY = self.statsScaleY
    
    for t = 1, 5 do
        local list = byType[t]
        if list then
            -- Sort by birth time (earliest at top)
            table.sort(list, function(a: Particle, b: Particle)
                return a.birthTime < b.birthTime
            end)
            
            local colX = startX + (t - 1) * gapX
            local currentY = startY
            
            for k = 1, #list do
                local p = list[k]
                local diameter = p.originalRadius * 2 * scaleY -- Apply Y scale
                
                -- Stack them (Growth direction -Y means subtracting size)
                currentY = currentY - (p.originalRadius * scaleY) -- Center offset
                p.statsX = colX
                p.statsY = currentY 
                
                -- Advance Y for next particle
                currentY = currentY - (p.originalRadius * scaleY)
            end
        end
    end
    
    self.statsCalculated = true
end

local function spawnSingleTimeMarker(self: ParticleSystemNode, data: PendingTimeMarker)
    local abTime = self.artboardTime
    local instance = abTime:instance()
    if instance then
        instance:advance(0)
        if instance.data and instance.data.time then
            local displayH = data.hour % 24
            instance.data.time.value = string.format("%02d:00", displayH)
        end
        
        local tm: TimeMarker = {
            x = data.x,
            y = data.y,
            instance = instance
        }
        table_insert(self.timeMarkers, tm)
    end
end

local function generateTimeMarkers(self: ParticleSystemNode)
	if #self.timeMarkers > 0 or #self.pendingTimeMarkers > 0 then return end

	local parts = self._particles
    local hourlyStats: { [number]: {sumX: number, sumY: number, n: number} } = {}

    -- Group by hour
    for i = 1, #parts do
        local p = parts[i]
        if not p.isGroupPoint then
            local h = mfloor(p.birthTime / 60)
            local stat = hourlyStats[h]
            if not stat then
                stat = {sumX=0, sumY=0, n=0}
                hourlyStats[h] = stat
            end
            stat.sumX = stat.sumX + p.x
            stat.sumY = stat.sumY + p.y
            stat.n = stat.n + 1
        end
    end

    -- Sort keys to spawn sequentially
    local hours = {}
    for h in pairs(hourlyStats) do table_insert(hours, h) end
    table.sort(hours)
    
    for _, h in ipairs(hours) do
        local stat = hourlyStats[h]
        if stat.n > 0 then
             table_insert(self.pendingTimeMarkers, {
                 x = 0, -- Set X position to 0 explicitly
                 y = stat.sumY / stat.n,
                 hour = h
             })
        end
    end
end

local function advance(self: ParticleSystemNode, seconds: number): boolean
	-- 0. Start Trigger Logic
	if not self.started then
		return true 
	end

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

        -- Group Point Position Animation (X offset)
        if p.isGroupPoint then
            if p.animDelay > 0 then
                p.animDelay = p.animDelay - 1
                
                -- Sync attraction logic with end of delay
                if p.animDelay == 0 then
                    if p.expanded then
                        self.selectedParticle = p
                        self.activeClusterId = p.clusterId
                        self.clusterIntensity = 0.0
                    else
                        if self.selectedParticle == p then
                            self.selectedParticle = nil
                            self.activeClusterId = nil
                        end
                    end
                end
            else
                local targetAnim = p.expanded and 1.0 or 0.0
                local animSpeed = dt * 1 -- 0.5s duration for snappier movement
                
                if p.animT ~= targetAnim then
                    if p.animT < targetAnim then
                        p.animT = mmin(targetAnim, p.animT + animSpeed)
                    else
                        p.animT = mmax(targetAnim, p.animT - animSpeed)
                    end
                    
                    local offset = cubicEase(p.animT) * self.groupPointShiftX
                    p.x = p.targetX + offset
                    p.prevX = p.x -- Prevent velocity buildup
                end
            end
        end

        if not p.sleeping then allSleeping = false end
	end
	
	-- Capture positions when everyone goes to sleep
	if allSleeping and #parts >= TOTAL_PARTICLES and not self.positionsCaptured then
        -- Instead of spawning instantly, we prepare the queue
		prepareGroupPointsQueue(self)
        calculateStatsPositions(self)
		generateTimeMarkers(self)

		for i = 1, #parts do
			local p = parts[i]
			p.targetX = p.x
			p.targetY = p.y
		end
		self.positionsCaptured = true
	end

    -- Process Spawning Queues
    if self.positionsCaptured then
        -- Group Points
        if #self.pendingGroupClusters > 0 then
            self.groupSpawnTimer = self.groupSpawnTimer + 1
            if self.groupSpawnTimer > 10 then
                self.groupSpawnTimer = 0
                local clusterData = table.remove(self.pendingGroupClusters, 1) -- Pop from start
                if clusterData then
                    spawnSingleGroupPoint(self, clusterData)
                end
            end
        end

        -- Time Markers (20 frames delay)
        if #self.pendingTimeMarkers > 0 then
            self.timeMarkerSpawnTimer = self.timeMarkerSpawnTimer + 1
            if self.timeMarkerSpawnTimer > 10 then
                 self.timeMarkerSpawnTimer = 0
                 local data = table.remove(self.pendingTimeMarkers, 1)
                 if data then
                    local d: PendingTimeMarker = data
                    spawnSingleTimeMarker(self, d)
                 end
            end
        end
    end

	-- If invalid state (e.g. new particles spawned), lose captured state
	if not allSleeping and self.positionsCaptured then
		-- Only reset if we are NOT interacting.
		-- Interaction (relax) moves particles but keeps 'sleeping' flag effectively by zeroing velocity.
		if self.selectedParticle == nil then
			self.positionsCaptured = false
			self.timeMarkers = {} 
            self.pendingTimeMarkers = {}
            self.timeMarkerSpawnTimer = 0
		end
	end

	-- Force relax if interacting or all asleep (captured)
	local forceRelax = (self.selectedParticle ~= nil) or self.positionsCaptured

    -- Ensure stats are calculated if we toggle late or params change
    if self.positionsCaptured and not self.statsCalculated then
        calculateStatsPositions(self)
    end
    -- Recalculate if we force update (optional optimizations could go here)
    if self.statsCalculated and self.stats then 
         -- Simple dirty check: Just recalc whenever stats is active to catch param changes
         -- In a bigger system we'd track param changes. For now, forcing recalc is cheap enough once frozen.
         self.statsCalculated = false 
         calculateStatsPositions(self)
    end


	if forceRelax then
		-- In relax mode: Just emit (if needed) and run relax solver
		-- We skip physics velocity integration to "switch off" physics
		relax(self, dt)
		
		-- Still advance graphics for instances
		for i = 1, #parts do
			parts[i].instance:advance(seconds)
		end
		
		-- Advance Markers
		for i = 1, #self.timeMarkers do
			self.timeMarkers[i].instance:advance(seconds)
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
                    else
                        p.sleepTimer = 0
                    end
                end

                
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
		-- Advance Markers
		for i = 1, #self.timeMarkers do
			self.timeMarkers[i].instance:advance(seconds)
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

	local parts = self._particles
	if not parts then return end
	 
    local useStats = self.stats
	local mat = self.mat

	for i = 1, #parts do
		local p = parts[i]
		renderer:save()
        
        local scale = p.radius / BASE_RADIUS
        if useStats and p.isGroupPoint then
            scale = 0
        end

		mat.xx = scale -- Scale based on radius relative to base
		mat.yy = scale
		mat.tx = p.x
		mat.ty = p.y
		renderer:transform(mat)
		p.instance:draw(renderer)
		renderer:restore()
	end

	-- Draw Time Markers
	local markers = self.timeMarkers
	if markers then
		for i = 1, #markers do
			local m = markers[i]
			renderer:save()
			mat.xx = 0.85
			mat.yy = 0.85
			mat.tx = 0
			mat.ty = m.y
			renderer:transform(mat)
			m.instance:draw(renderer)
			renderer:restore()
		end
	end
end

return function(): Node<ParticleSystemNode>
	return {
		artboard1 = late(),
		artboard2 = late(),
		artboard3 = late(),
		artboard4 = late(),
		artboard5 = late(),
		artboardGroup = late(),
		artboardTime = late(),
		
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
		
		globalClusterStrength = 0.5,
		activeClusterStrength = 5.0,

        stats = false,
        statsStartX = -200,
        statsStartY = 400, -- Adjusted default considering Upward growth
        statsGapX = 100,
        statsScaleY = 1.0,

		boxWidth = 150,
		boxHeight = 700,
		boxY = 200,
		
		boxPath = Path.new(),
		emitterPath = Path.new(),
		boxPaint = Paint.new(),
		emitterPaint = Paint.new(),
		lastSpawnX = 0,
		spawnDirection = 0,

		_particles = {},
		packets = {},
		packetIndex = 1,
		packetDelayCounter = 0,
		timeMinutes = 0,
		mat = Mat2D.identity(),
		grid = {},

		nextId = 1,

        groupedClusters = {},
        timeMarkers = {},
        statsCalculated = false,

		positionsCaptured = false,
		selectedParticle = nil,
		activeClusterId = nil,
		clusterIntensity = 0.0,
		pointerPos = {x=0, y=0},
		
		groupPointsCreated = false,
		groupPointX = 150,
		groupPointShiftX = 80,
		pendingGroupClusters = { },
    	groupSpawnTimer = 0,
        pendingTimeMarkers = {},
        timeMarkerSpawnTimer = 0,

		started = false,

		init = init,
		advance = advance,
		activate = activate,
		draw = draw,
		pointerDown = pointerDown,
		pointerUp = pointerUp,
		pointerMove = pointerMove,
	}
end

