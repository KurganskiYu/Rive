-- Scatter_v1: Grid/Tetrahedral scatter with delay
-- Optimized for Rive Lua Runtime

-- Type definitions
type PointVM = {
	percentFrom: Property<number>, 
	percentTo: Property<number>,
	active: Property<boolean>,
}

type Point = {
	instance: Artboard<PointVM>,
	x: number,
	y: number,
	index: number,
	-- NEW: metadata to track how/when point was created
	creationOrder: number?,
	isActive: boolean?, -- Local tracking of active property
}

type ScatterNode = {
	-- Inputs
	artboard: Input<Artboard<PointVM>>,
	areaWidth: Input<number>,
	areaHeight: Input<number>,
	countX: Input<number>,
	countY: Input<number>,
	delayFrames: Input<number>,
	pointScale: Input<number>,

	-- Main View Model parameters
	daysAmount: number,
	percentToData: string,
	percentToValues: { number }, -- NEW: parsed values used for lookup

	-- State
	points: { Point },
	spawnIndex: number,
	frameCounter: number,
	mat: Mat2D,

	-- NEW state helpers
	created: { [number]: boolean },
} 

-- Localize math for performance
local mfloor = math.floor
local mmax = math.max
local mmin = math.min
local minsert = table.insert
local mremove = table.remove

local function init(self: ScatterNode, context: Context): boolean
	-- Make a reference to the main view model
  	local vm = context:viewModel()
	if vm then
  		-- Get properties from the main view model
  		local daysAmountProp = vm:getNumber('daysAmount')
		if daysAmountProp then
			self.daysAmount = daysAmountProp.value
		end

		local percentToDataProp = vm:getString('percentToData')
		if percentToDataProp then
			self.percentToData = percentToDataProp.value
		end
	end

	-- Parse percentToData SSV string into table
	self.percentToValues = {}
	if type(self.percentToData) == "string" then
		for val in self.percentToData:gmatch("%S+") do
			-- Robustness: Remove commas/semicolons if present, just in case
			val = val:gsub("[,;]", "")
			local num = tonumber(val)
			if num then
				minsert(self.percentToValues, num)
			end
		end
	end

	self.points = {}
	self.spawnIndex = 0
	self.frameCounter = 0
	self.mat = Mat2D.identity()

	-- NEW: radial spawn helpers
	self.created = {}

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
	
	pt.x = x
	pt.y = y
end

local function createPoint(self: ScatterNode, index: number)
	-- Safety check: Ensure artboard input is connected
	if not self.artboard then return end

	-- Avoid double-creating same index as active
	if self.created[index] then return end

	-- Determine percentTo value from parsed data (default to 0)
	local pToVal = 0
	if self.percentToValues and self.percentToValues[index + 1] then
		pToVal = self.percentToValues[index + 1]
	end

	-- Create new point if no reusable instance found
	local inst = self.artboard:instance()
	if not inst then return end
	
	inst:advance(0)
	
	local pt: Point = {
		instance = inst,
		x = 0,
		y = 0,
		index = index,
		isActive = false,
	}

	pt.creationOrder = #self.points + 1

	if inst.data then
		if inst.data.active then inst.data.active.value = false end
		if inst.data.percentFrom then inst.data.percentFrom.value = 0 end
		if inst.data.percentTo then inst.data.percentTo.value = pToVal end
	end

	updatePointPosition(self, pt, index)
	minsert(self.points, pt)
	self.created[index] = true
end

local function advance(self: ScatterNode, seconds: number): boolean
	local cx = mmax(1, mfloor(self.countX))
	local cy = mmax(1, mfloor(self.countY))
	local totalPoints = cx * cy -- grid capacity

	-- Limit max points by daysAmount if provided
	if self.daysAmount then
		totalPoints = mmin(totalPoints, self.daysAmount)
	end
	
	-- 1. Immediate Spawning: Ensure all needed points exist
	while self.spawnIndex < totalPoints do
		createPoint(self, self.spawnIndex)
		self.spawnIndex = self.spawnIndex + 1
	end

	-- Global frame counter for activation logic
	self.frameCounter = self.frameCounter + 1
	local delay = mfloor(self.delayFrames)

	-- 3. Update Active Points: update positions and handle delayed activation
	for i, pt in ipairs(self.points) do
		updatePointPosition(self, pt, pt.index)

		-- Activation Logic
		if not pt.isActive then
			local activationFrame = pt.index * delay
			if self.frameCounter >= activationFrame then
				pt.isActive = true
				if pt.instance.data and pt.instance.data.active then
					pt.instance.data.active.value = true
				end
			end
		end

		if pt.instance then
			pt.instance:advance(seconds)
		end
	end
	
	return true
end

local function draw(self: ScatterNode, renderer: Renderer)
	local mat = self.mat
	local s = self.pointScale
	
	-- Apply uniform scale
	mat.xx = s
	mat.yy = s

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
		delayFrames = 0,
		pointScale = 1.0,

		points = {},
		spawnIndex = 0,
		frameCounter = 0,
		mat = late(),

		created = {},
		percentToValues = {},
		percentToData = "",
		daysAmount = 31,

		init = init,
		advance = advance,
		draw = draw,
	}
end

