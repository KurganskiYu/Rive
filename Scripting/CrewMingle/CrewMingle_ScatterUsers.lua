-- ScatterUsers.lua: Hexagonal grid scatter with two-phase activation
-- Phase 1: Spawn points one by one with an auto-scaled delay.
-- Phase 2: Activate a random subset of points one by one after all are spawned.
-- Features:
--  - Grid automatically auto-scales to perfectly fit the specified `areaWidth` using `radius` spacing.
--  - Last rows are artificially padded to maintain interlocking honeycomb visual symmetry.
--  - Edge columns are generated but never chosen during the random active selection.
--  - Dynamic `multiplier`: Total spawned points scale smoothly from 3x down to 2x when friends > 12.
--  - Dynamic `delayFrames`: Delay speed doubles (delay drops 50%+) when friends > 12 to save time.
--  - `drawBounds`: Optional debug rectangle outlining the grid corner points.

-- Type definitions
type PointVM = {
	active: Property<boolean>,
	picture: Property<Image>,
}
 
type Point = {
	instance: Artboard<PointVM>,
	x: number,
	y: number,
	index: number,
	creationOrder: number?,
	isActive: boolean?,
}

type ScatterNode = {
	-- Inputs
	artboard: Input<Artboard<PointVM>>,
	areaWidth: Input<number>,
	areaHeight: Input<number>,
	friendsNum: Input<number>,
	delayFrames: Input<number>,
	pointScale: Input<number>,
	multiplier: Input<number>,
	radius: Input<number>,
	drawBounds: Input<boolean>,

	-- Main View Model parameters
	delay: number?,
	delayProp: Property<number>?,

	-- State
	points: { Point },
	spawnIndex: number,
	frameCounter: number,
	mat: Mat2D,
	created: { [number]: boolean },
	sharedImage: Image?,
	activeIndices: { number },
	activeIndicesReady: boolean,
	autoScale: number,
	offsetX: number,
	offsetY: number,
	sx: number,
	sy: number,
	cx: number?,
	cy: number?,
}
 
-- Localize math for performance
local mfloor = math.floor
local mceil = math.ceil
local msqrt = math.sqrt
local mmax = math.max
local mmin = math.min
local minsert = table.insert
local mremove = table.remove

-- Calculate grid columns/rows as square as possible from a point count
local function calcGrid(maxPoints: number, w: number, h: number): (number, number)
	local r = w > 0 and h > 0 and (w / h) or 1
	local targetCx = mmax(1, mfloor(msqrt(maxPoints * r / 2) + 0.5))
	local cx = mmax(1, targetCx)
	if cx <= 1 then
		return 1, maxPoints
	end
	local pairCount = 2 * cx - 1
	local rowPairs = mfloor(maxPoints / pairCount)
	local rem = maxPoints % pairCount
	local cy = rowPairs * 2
	if rem > 0 then
		if rem <= cx then
			cy = cy + 1
		else
			cy = cy + 2
		end
	end
	return cx, mmax(1, cy)
end
 
local function isEdgeColumn(index: number, cx: number): boolean
	local pairCount = 2 * cx - 1
	local rem = index % pairCount
	if rem < cx then
		return rem == 0 or rem == cx - 1
	else
		return rem == 0 or rem == cx - 2
	end
end

-- Fisher-Yates shuffle; returns k random 1-based indices from 1..n filtering edges
local function pickActiveIndices(n: number, k: number, cx: number): { number }
	local validIndices: { number } = {}
	for i = 1, n do
		if cx <= 2 or not isEdgeColumn(i - 1, cx) then
			minsert(validIndices, i)
		end
	end
	
	local numValid = #validIndices
	if numValid == 0 then return {} end

	for i = numValid, 2, -1 do
		local j = math.random(i)
		validIndices[i], validIndices[j] = validIndices[j], validIndices[i]
	end
	
	local result: { number } = {}
	local take = mmin(k, numValid)
	for i = 1, take do
		result[i] = validIndices[i]
	end
	return result
end

-- Get hex grid position for a linear index
-- Odd rows have one fewer point and are shifted right by half the column spacing
local function getHexPosition(self: ScatterNode, index: number, cx: number, cy: number): (number, number)
	local sx = self.sx or 130
	local sy = self.sy or 65

	if cx <= 1 then
		return self.offsetX, self.offsetY + index * sy
	end
	
	local pairCount = 2 * cx - 1
	local rowPairs = mfloor(index / pairCount)
	local rem = index % pairCount
	
	local rowOffset, col
	if rem < cx then
		rowOffset = 0
		col = rem
	else
		rowOffset = 1
		col = rem - cx
	end
	
	local row = rowPairs * 2 + rowOffset
	local x = self.offsetX + col * sx + (row % 2 == 1 and sx * 0.5 or 0)
	local y = self.offsetY + row * sy

	return x, y
end

local function init(self: ScatterNode, context: Context): boolean
	local vm = context:viewModel()
	if vm then
		local delayProp = vm:getNumber('delay')
		if delayProp then
			self.delayProp = delayProp
			self.delay = delayProp.value
		end
	end

	self.sharedImage = context:image('image_4')

	self.points = {}
	self.spawnIndex = 0
	self.frameCounter = 0
	self.mat = Mat2D.identity()
	self.created = {}
	self.activeIndices = {}
	self.activeIndicesReady = false
	self.autoScale = 1.0
	self.offsetX = 0
	self.offsetY = 0
	self.sx = 130
	self.sy = 65
	self.cx = 0
	self.cy = 0

	return true
end

local function createPoint(self: ScatterNode, index: number, cx: number, cy: number)
	if not self.artboard then return end
	if self.created[index] then return end

	local inst = self.artboard:instance()
	if not inst then return end

	inst:advance(0)

	local x, y = getHexPosition(self, index, cx, cy)

	local pt: Point = {
		instance = inst,
		x = x,
		y = y,
		index = index,
		isActive = false,
	}

	pt.creationOrder = #self.points + 1

	if inst.data then
		if inst.data.active then
			inst.data.active.value = false
		end
		if inst.data.picture and self.sharedImage then
			inst.data.picture.value = self.sharedImage
		end
	end
 
	minsert(self.points, pt)
	self.created[index] = true
end
 
local function advance(self: ScatterNode, seconds: number): boolean
	-- Sync delay from VM
	if self.delayProp and self.delayProp.value ~= self.delay then
		self.delay = self.delayProp.value
	end

	local friendsNum = mmax(1, mfloor(self.friendsNum))
	local multiplierInput = mmax(1, self.multiplier or 4)
	
	-- Scale multiplier dynamically
	-- <= 12 friends: scale = 1.0 (normal multiplier)
	-- >= 30 friends: scale = 0.666 (e.g. converting 3 down to 2)
	local multScale = 1.0
	if friendsNum > 12 then
		local t = mmin(1, (friendsNum - 12) / 18)
		multScale = 1.0 - (t * (1/3))
	end
	
	local basePoints = mmax(1, mfloor(friendsNum * multiplierInput * multScale + 0.5))
	
	local areaW = self.areaWidth or 500
	local areaH = self.areaHeight or 500
	local cx, cy = calcGrid(basePoints, areaW, areaH)
 
	local totalPoints = basePoints
	if cx > 1 then
		local pairCount = 2 * cx - 1
		local rowPairs = mfloor(cy / 2)
		totalPoints = rowPairs * pairCount + (cy % 2 == 1 and cx or 0)
	else
		totalPoints = cy
	end

	local radius = self.radius or 65
	local gridPhysW = (cx <= 1) and (radius * 2) or ((cx - 1) * (radius * 2) + radius * 2)
	local gridPhysH = (cy <= 1) and (radius * 2) or ((cy - 1) * radius + radius * 2)
	
	local scaleX = areaW / mmax(1, gridPhysW)
	self.autoScale = scaleX
	
	self.sx = radius * 2 * self.autoScale
	self.sy = radius * self.autoScale
	self.cx = cx
	self.cy = cy

	local finalW = (cx <= 1) and self.sx or ((cx - 1) * self.sx + self.sx)
	local finalH = (cy <= 1) and self.sx or ((cy - 1) * self.sy + self.sx)
	
	self.offsetX = (areaW - finalW) * 0.5 + self.sx * 0.5
	self.offsetY = (areaH - finalH) * 0.5 + self.sx * 0.5

	local delayInput = self.delay or self.delayFrames
	local delayScale = 1.0
	if friendsNum > 12 then
		-- slope is 0.5 drop for every 18 friends above 12
		local t = (friendsNum - 12) / 18
		delayScale = mmax(0, 1.0 - (t * 0.5))
	end
	-- round to nearest frame, clamping to 1 minimum
	local delay = mmax(1, mfloor(delayInput * delayScale + 0.5))

	-- Handle decreasing friendsNum: remove excess points and reset active selection
	if #self.points > totalPoints then
		while #self.points > totalPoints do
			local pt = mremove(self.points)
			if pt then
				self.created[pt.index] = nil
			end
		end
		self.activeIndices = {}
		self.activeIndicesReady = false
	end
	self.spawnIndex = #self.points

	self.frameCounter = self.frameCounter + 1

	-- Phase 1: Spawn points one by one with delay
	-- Point i (0-based) spawns when frameCounter >= i * delay
	while self.spawnIndex < totalPoints do
		if delay == 0 or self.frameCounter >= self.spawnIndex * delay then
			createPoint(self, self.spawnIndex, cx, cy)
			self.spawnIndex = self.spawnIndex + 1
		else
			break
		end
	end

	-- Pick the random active subset once, the moment all points are spawned
	if not self.activeIndicesReady and #self.points == totalPoints then
		self.activeIndices = pickActiveIndices(totalPoints, friendsNum, cx)
		self.activeIndicesReady = true
	end

	-- Phase 2: Activate the chosen subset one by one after all are spawned
	if self.activeIndicesReady then
		for j, ptIdx in ipairs(self.activeIndices) do
			local pt = self.points[ptIdx]
			if pt and not pt.isActive then
				local activationFrame = totalPoints * delay + (j - 1) * delay
				if delay == 0 or self.frameCounter >= activationFrame then
					pt.isActive = true
					if pt.instance.data and pt.instance.data.active then
						pt.instance.data.active.value = true
					end
				end
			end
		end
	end

	-- Advance all points (position + animation tick)
	for _, pt in ipairs(self.points) do
		pt.x, pt.y = getHexPosition(self, pt.index, cx, cy)
		if pt.instance then
			pt.instance:advance(seconds)
		end
	end

	return true
end

local function draw(self: ScatterNode, renderer: Renderer)
	if self.drawBounds and self.cx and self.cy and self.cx > 0 and self.cy > 0 then
		local w = (self.cx - 1) * self.sx
		local h = (self.cy - 1) * self.sy
		local p = Path.new()
		p:moveTo(Vector.xy(self.offsetX, self.offsetY))
		p:lineTo(Vector.xy(self.offsetX + w, self.offsetY))
		p:lineTo(Vector.xy(self.offsetX + w, self.offsetY + h))
		p:lineTo(Vector.xy(self.offsetX, self.offsetY + h))
		p:close()

		local paint = Paint.with({
			style = 'stroke',
			color = 0x88FFFFFF,
			thickness = 2,
			cap = 'round',
			join = 'round'
		})
		renderer:drawPath(p, paint)
	end

	local mat = self.mat
	local s = self.autoScale

	mat.xx = s
	mat.yy = s

	for _, pt in ipairs(self.points) do
		if pt.instance then
			renderer:save()
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
		friendsNum = 10,
		delayFrames = 6,
		multiplier = 3,
		radius = 65,
		pointScale = 1.0,
		drawBounds = false,

		points = {},
		spawnIndex = 0,
		frameCounter = 0,
		mat = Mat2D.identity(),
		created = {},
		sharedImage = nil,
		activeIndices = {},
		activeIndicesReady = false,
		delay = nil,
		delayProp = nil,
		autoScale = 1.0,
		offsetX = 0,
		offsetY = 0,
		sx = 130,
		sy = 65,
		cx = 0,
		cy = 0,

		init = init,
		advance = advance,
		draw = draw,
	}
end

