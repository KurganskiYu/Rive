-- Scatter_v1: Grid/Tetrahedral scatter with delay
-- Optimized for Rive Lua Runtime

-- Type definitions
type PointVM = {
	pType: Property<number>,
	deactivate: Property<boolean>,
}

type Point = {
	instance: Artboard<PointVM>,
	x: number,
	y: number,
	pType: number,
	index: number,
	-- NEW: metadata to track how/when point was created
	createdByRadial: boolean?,
	creationOrder: number?,
	deactivated: boolean?, -- TRACKING: Is it logically deactivated?
}

type ScatterNode = {
	-- Inputs
	artboard: Input<Artboard<PointVM>>,
	areaWidth: Input<number>,
	areaHeight: Input<number>,
	countX: Input<number>,
	countY: Input<number>,
	tetrahedral: Input<boolean>,
	delayFrames: Input<number>,

	-- NEW radial spawn inputs
	radialSpawn: Input<boolean>,
	spawnCenterX: Input<number>,
	spawnCenterY: Input<number>,
	spawnSpeed: Input<number>,

	-- NEW clear inputs
	clear: Input<Trigger>,            -- trigger to start gradual clear
	clearDelayFrames: Input<number>,  -- delay between deletions for sequential clear

	-- State
	points: { Point },
	pointsMap: { [number]: Point }, -- NEW: Map for O(1) access
	spawnIndex: number,
	frameCounter: number,
	mat: Mat2D,

	-- NEW caching helpers
	cx: number,
	cy: number,
	sx: number,
	sy: number,
	lastTetrahedral: boolean,

	-- NEW state helpers
	created: { [number]: boolean },
	spawnRadius: number,

	-- NEW clear helpers
	creationList: { number },     -- indices in creation order
	creationCounter: number,
	clearing: boolean,
	clearFrameCounter: number,
	clearSpawnRadius: number,
} 

-- Localize math for performance
local mfloor = math.floor
local mmax = math.max
local minsert = table.insert
local mremove = table.remove

-- Visual Grid Configuration (17 rows x 7 cols)
-- Manually edit these values to set particle types 
local typeGrid = {
	1, 1, 1, 1, 1, 1, 1,
	  1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 2, 1, 0, 3,
	  1, 1, 2, 2, 1, 2, 1,
	1, 1, 3, 3, 1, 1, 1,
	  1, 0, 1, 0, 1, 0, 1,
	1, 0, 0, 3, 0, 0, 1,
	  1, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 1,
	  1, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 1,
	  1, 0, 0, 0, 0, 1, 1,
	1, 1, 1, 0, 0, 1, 0,
	  1, 1, 1, 3, 3, 1, 1,
	1, 0, 1, 2, 3, 2, 1,
	  1, 2, 1, 1, 3, 1, 1,
	1, 1, 3, 1, 1, 1, 1,
	  1, 1, 1, 1, 1, 1, 1,
}

local function computeGridXY(self: ScatterNode, index: number)
	local row = mfloor(index / self.cx)
	local col = index % self.cx

	local x = col * self.sx
	local y = row * self.sy

	if self.tetrahedral and (row % 2 == 1) then
		x = x + (self.sx * 0.5)
	end

	return x, y
end

local function init(self: ScatterNode, context: Context): boolean
	self.points = {}
	self.pointsMap = {}
	self.spawnIndex = 0
	self.frameCounter = mfloor(self.delayFrames) -- Start ready if delay is 0
	self.mat = Mat2D.identity()

	-- NEW: radial spawn helpers
	self.created = {}
	self.spawnRadius = 0

	-- Caching
	self.cx = 0
	self.cy = 0
	self.sx = 0
	self.sy = 0
	self.lastTetrahedral = false

	-- NEW: clearing state
	self.creationList = {}
	self.creationCounter = 0
	self.clearing = false
	self.clearFrameCounter = 0
	self.clearSpawnRadius = 0

	return true
end

local function updatePointPosition(self: ScatterNode, pt: Point, index: number)
	-- Map linear index to 2D grid
	local row = mfloor(index / self.cx)
	local col = index % self.cx
	
	local x = col * self.sx
	local y = row * self.sy
	
	-- Tetrahedral shift: offset every odd row by half a cell width
	if self.tetrahedral and (row % 2 == 1) then
		x = x + (self.sx * 0.5)
	end
	
	pt.x = x
	pt.y = y
end

local function removePointByIndex(self: ScatterNode, index: number)
	-- Instead of deleting, we deactivate the point instance flag and property
	local pt = self.pointsMap[index]
	if pt and not pt.deactivated then
		pt.deactivated = true
		if pt.instance.data and pt.instance.data.deactivate then
			pt.instance.data.deactivate.value = true
		end
	end
	
	self.created[index] = nil
	-- remove from creationList to keep sequential logic flowing
	for i = #self.creationList, 1, -1 do
		if self.creationList[i] == index then
			mremove(self.creationList, i)
			break
		end
	end
end

local function createPoint(self: ScatterNode, index: number)
	-- Safety check: Ensure artboard input is connected
	if not self.artboard then return end

	-- Avoid double-creating same index as active
	if self.created[index] then return end

	-- Reuse check: look for existing point for this index in the pool
	local reused: Point? = self.pointsMap[index]

	if reused then 
		reused.deactivated = false
		reused.createdByRadial = self.radialSpawn
		self.creationCounter = (self.creationCounter or 0) + 1
		reused.creationOrder = self.creationCounter
		minsert(self.creationList, index)

		-- Reactivate Property
		if reused.instance.data and reused.instance.data.deactivate then
			reused.instance.data.deactivate.value = false
		end

		local t = typeGrid[index + 1] or 1
		if reused.pType ~= t then
			reused.pType = t
			if reused.instance.data and reused.instance.data.pType then
				reused.instance.data.pType.value = t
			end
		end

		updatePointPosition(self, reused, index)
		self.created[index] = true
		return
	end

	-- Create new point if no reusable instance found
	local inst = self.artboard:instance()
	if not inst then return end
	
	inst:advance(0)
	
	local t = typeGrid[index + 1] or 1
	
	local pt: Point = {
		instance = inst,
		x = 0,
		y = 0,
		pType = t,
		index = index,
		createdByRadial = self.radialSpawn,
		deactivated = false,
	}

	self.creationCounter = (self.creationCounter or 0) + 1
	pt.creationOrder = self.creationCounter
	minsert(self.creationList, index)

	if inst.data then
		if inst.data.pType then inst.data.pType.value = t end
		if inst.data.deactivate then inst.data.deactivate.value = false end
	end

	updatePointPosition(self, pt, index)
	minsert(self.points, pt)
	self.pointsMap[index] = pt
	self.created[index] = true
end

local function clear(self: ScatterNode)
	-- Trigger handler: begin gradual clear
	self.clearing = true
	self.clearFrameCounter = 0

	local centerX = self.spawnCenterX or (self.areaWidth * 0.5)
	local centerY = self.spawnCenterY or (self.areaHeight * 0.5)
	local maxDist2 = 0
	for _, pt in ipairs(self.points) do
		if pt.createdByRadial and not pt.deactivated then
			local dx = pt.x - centerX
			local dy = pt.y - centerY
			local d2 = dx * dx + dy * dy
			if d2 > maxDist2 then maxDist2 = d2 end
		end
	end
	if maxDist2 > 0 then
		self.clearSpawnRadius = math.sqrt(maxDist2)
	else
		-- fallback small radius so radial phase has nothing to do
		self.clearSpawnRadius = 0
	end
end

local function advance(self: ScatterNode, seconds: number): boolean
	local cx = mmax(1, mfloor(self.countX))
	local cy = mmax(1, mfloor(self.countY))
	local sx = 0
	if cx > 1 then sx = self.areaWidth / (cx - 1) end
	local sy = 0
	if cy > 1 then sy = self.areaHeight / (cy - 1) end

	local gridChanged = (cx ~= self.cx or cy ~= self.cy or sx ~= self.sx or sy ~= self.sy or self.tetrahedral ~= self.lastTetrahedral)
	
	self.cx = cx
	self.cy = cy
	self.sx = sx
	self.sy = sy
	self.lastTetrahedral = self.tetrahedral

	local totalPoints = cx * cy
	local delay = mfloor(self.delayFrames)
	
	-- 0. If clearing, perform inverse-deletion (deactivation) instead of spawning
	if self.clearing then
		-- Radial clearing
		if self.clearSpawnRadius and self.clearSpawnRadius > 0 then
			self.clearSpawnRadius = self.clearSpawnRadius - (self.spawnSpeed * seconds)
			local centerX = self.spawnCenterX or (self.areaWidth * 0.5)
			local centerY = self.spawnCenterY or (self.areaHeight * 0.5)
			local r2 = self.clearSpawnRadius * self.clearSpawnRadius

			for i = #self.points, 1, -1 do
				local pt = self.points[i]
				if pt and pt.createdByRadial and not pt.deactivated then
					local dx = pt.x - centerX
					local dy = pt.y - centerY
					if self.clearSpawnRadius <= 0 or (dx * dx + dy * dy) > r2 then
						removePointByIndex(self, pt.index)
					end
				end
			end
			if self.clearSpawnRadius < 0 then self.clearSpawnRadius = 0 end
		end
		
		-- Sequential clearing logic remains unchanged as it uses creationList
		if #self.creationList > 0 then
			local clearDelay = mfloor(self.clearDelayFrames)
			if clearDelay <= 0 then
				-- remove all remaining sequential-created points immediately
				while #self.creationList > 0 do
					local idx = mremove(self.creationList)
					if idx then removePointByIndex(self, idx) end
				end
			else
				self.clearFrameCounter = self.clearFrameCounter + 1
				if self.clearFrameCounter >= clearDelay then
					-- remove last-created index
					local idx = mremove(self.creationList)
					if idx then removePointByIndex(self, idx) end
					self.clearFrameCounter = 0
				end
			end
		end

		-- If no points remain active, end clearing state
		local anyActive = false
		for _, pt in ipairs(self.points) do
			if not pt.deactivated then
				anyActive = true
				break
			end
		end

		if not anyActive then
			self.clearing = false
			self.clearFrameCounter = 0
			self.clearSpawnRadius = 0
			self.creationList = {}
			self.creationCounter = 0
			-- Also reset spawnIndex so future spawning behaves correctly
			self.spawnIndex = 0
			self.spawnRadius = 0
		end

		-- Update all pool points (including those playing deactivation animations)
		for i, pt in ipairs(self.points) do
			if gridChanged then updatePointPosition(self, pt, pt.index) end
			if pt.instance then pt.instance:advance(seconds) end
		end

		return true
	end

	-- 1a. Radial spawning: grow radius and activate points inside circle
	if self.radialSpawn then
		-- grow radius (spawnSpeed in units per second)
		self.spawnRadius = self.spawnRadius + (self.spawnSpeed * seconds)

		local centerX = self.spawnCenterX or (self.areaWidth * 0.5)
		local centerY = self.spawnCenterY or (self.areaHeight * 0.5)
		local r2 = self.spawnRadius * self.spawnRadius

		for i = 0, totalPoints - 1 do
			if not self.created[i] then
				local x, y = computeGridXY(self, i)
				local dx = x - centerX
				local dy = y - centerY 
				if dx * dx + dy * dy <= r2 then
					createPoint(self, i)
				end
			end
		end
	else
		-- 1b. Sequential spawning (existing behavior)
		if self.spawnIndex < totalPoints then
			if delay <= 0 then
				-- No delay: Spawn everything remaining in this frame
				while self.spawnIndex < totalPoints do
					createPoint(self, self.spawnIndex)
					self.spawnIndex = self.spawnIndex + 1
				end
			else
				-- Delay active: Count frames
				self.frameCounter = self.frameCounter + 1
				if self.frameCounter >= delay then
					-- skip already-created indices
					while self.spawnIndex < totalPoints and self.created[self.spawnIndex] do
						self.spawnIndex = self.spawnIndex + 1
					end
					if self.spawnIndex < totalPoints then
						createPoint(self, self.spawnIndex)
						self.spawnIndex = self.spawnIndex + 1
					end
					self.frameCounter = 0
				end
			end
		end
	end

	-- 2. Handle Count Reduction: find active points that need deactivation
	for _, pt in ipairs(self.points) do
		if not pt.deactivated and pt.index >= totalPoints then
			removePointByIndex(self, pt.index)
		end
	end
	
	-- ensure spawnIndex points at the next uncreated/deactivated index
	local nextIndex = 0
	while nextIndex < totalPoints and self.created[nextIndex] do
		nextIndex = nextIndex + 1
	end
	self.spawnIndex = nextIndex

	-- 3. Update Active Points: update positions using stored index (handles animated grid)
	for i, pt in ipairs(self.points) do
		if gridChanged then updatePointPosition(self, pt, pt.index) end

		if pt.instance then
			-- pType set only in createPoint/reactivation unless it needs per-frame sync
			-- If typeGrid changes dynamically, we'd need this, but it seems static.
			pt.instance:advance(seconds)
		end
	end
	
	return true
end

local function draw(self: ScatterNode, renderer: Renderer)
	local mat = self.mat
	for _, pt in ipairs(self.points) do
		if pt.instance then
			renderer:save()
			-- Apply translation
			mat.tx = pt.x
			mat.ty = pt.y
			renderer:transform(mat)
			
			pt.instance:draw(renderer)
			renderer:restore()
		end
	end
end

-- Factory function
return function(): Node<ScatterNode>
	return {
		artboard = late(),
		areaWidth = 500,
		areaHeight = 500,
		countX = 5,
		countY = 5,
		tetrahedral = false,
		delayFrames = 0,

		-- NEW radial spawn defaults
		radialSpawn = false,
		spawnCenterX = 250,
		spawnCenterY = 250,
		spawnSpeed = 200, -- pixels per second

		-- NEW clear inputs
		clearDelayFrames = 0,

		points = {},
		pointsMap = {},
		spawnIndex = 0,
		frameCounter = 0,
		mat = late(),

		cx = 0,
		cy = 0,
		sx = 0,
		sy = 0,
		lastTetrahedral = false,

		created = {},
		spawnRadius = 0,

		-- NEW clearing state
		creationList = {},
		creationCounter = 0,
		clearing = false,
		clearFrameCounter = 0,
		clearSpawnRadius = 0,

		init = init,
		advance = advance,
		draw = draw,
		-- expose trigger handler (runtime binds trigger to same-named function)
		clear = clear,
	}
end

