-- Scatter_v1: Grid/Tetrahedral scatter with delay
-- Optimized for Rive Lua Runtime

-- Type definitions
type PointVM = {
	pType: Property<number>,
}

type Point = {
	instance: Artboard<PointVM>,
	x: number,
	y: number,
	pType: number,
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
	
	-- State
	points: { Point },
	spawnIndex: number,
	frameCounter: number,
	mat: Mat2D,
	

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
	1, 1, 1, 2, 1, 0, 1,
	  1, 1, 2, 2, 1, 1, 1,
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
	  1, 1, 1, 1, 3, 1, 1,
	1, 1, 1, 1, 1, 1, 1,
	  1, 1, 1, 1, 1, 1, 1,
}

local function init(self: ScatterNode, context: Context): boolean
	self.points = {}
	self.spawnIndex = 0
	self.frameCounter = mfloor(self.delayFrames) -- Start ready if delay is 0
	self.mat = Mat2D.identity()
	return true
end

local function updatePointPosition(self: ScatterNode, pt: Point, index: number)
	local cx = mmax(1, mfloor(self.countX))
	local cy = mmax(1, mfloor(self.countY))
	
	-- Map linear index to 2D grid
	local row = mfloor(index / cx)
	local col = index % cx
	
	-- Calculate grid spacing (distribute evenly across area)
	local sx = 0
	if cx > 1 then sx = self.areaWidth / (cx - 1) end
	
	local sy = 0
	if cy > 1 then sy = self.areaHeight / (cy - 1) end
	
	local x = col * sx
	local y = row * sy
	
	-- Tetrahedral shift: offset every odd row by half a cell width
	if self.tetrahedral and (row % 2 == 1) then
		x = x + (sx * 0.5)
	end
	
	pt.x = x
	pt.y = y
end

local function createPoint(self: ScatterNode, index: number)
	-- Safety check: Ensure artboard input is connected
	if not self.artboard then return end
	
	local inst = self.artboard:instance()
	if not inst then return end
	
	-- We capture the type here, but apply binding in advance()
	
	inst:advance(0)
	
	-- Determine Type from hardcoded Grid (using linear index)
	-- Fallback to type 1 if we run out of defined grid types
	local t = typeGrid[index + 1] or 1
	
	local pt: Point = {
		instance = inst,
		x = 0,
		y = 0,
		pType = t,
	}

	-- Initialize Data Binding
	if inst.data and inst.data.pType then
		inst.data.pType.value = pt.pType
	end

	-- Initialize position immediately based on current grid settings
	updatePointPosition(self, pt, index)
	
	minsert(self.points, pt)
end

local function advance(self: ScatterNode, seconds: number): boolean
	local cx = mmax(1, mfloor(self.countX))
	local cy = mmax(1, mfloor(self.countY))
	local totalPoints = cx * cy
	local delay = mfloor(self.delayFrames)
	
	-- 1. Manage Spawning
	-- We only spawn if we haven't reached the target totalPoints
	-- and if we have a valid artboard source.
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
				createPoint(self, self.spawnIndex)
				self.spawnIndex = self.spawnIndex + 1
				self.frameCounter = 0
			end
		end
	end
	
	-- 2. Handle Count Reduction
	-- If user reduces grid size, remove excess points immediately
	if #self.points > totalPoints then
		for i = #self.points, totalPoints + 1, -1 do
			mremove(self.points, i)
		end
		-- Reset spawn index to max so we don't try to spawn more
		self.spawnIndex = totalPoints 
	end
	
	-- 3. Update Active Points
	-- Re-calculate positions every frame to support animating Area/Grid params
	for i, pt in ipairs(self.points) do
		updatePointPosition(self, pt, i - 1)
		
		if pt.instance then
			-- Enforce Data Binding: Sync point state to instance ViewModel
			-- We do this every frame to ensure persistence
			if pt.instance.data and pt.instance.data.pType then
				pt.instance.data.pType.value = pt.pType
			end

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
		
		points = {},
		spawnIndex = 0,
		frameCounter = 0,
		-- 'late()' here satisfies the type checker; real object created in init()
		mat = late(),
		
		init = init,
		advance = advance,
		draw = draw,
	}
end

