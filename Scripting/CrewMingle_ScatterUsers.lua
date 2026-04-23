-- ScatterUsers.lua: Hexagonal grid scatter with two-phase activation
-- Phase 1: spawn points one by one with delay
-- Phase 2: activate points one by one with the same delay, after all are spawned

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
local function calcGrid(maxPoints: number): (number, number)
	local cx = mmax(1, mfloor(msqrt(maxPoints) + 0.5))
	local cy = mmax(1, mceil(maxPoints / cx))
	return cx, cy
end

-- Fisher-Yates shuffle; returns k random 1-based indices from 1..n
local function pickRandomIndices(n: number, k: number): { number }
	local indices: { number } = {}
	for i = 1, n do
		indices[i] = i
	end
	for i = n, 2, -1 do
		local j = math.random(i)
		indices[i], indices[j] = indices[j], indices[i]
	end
	local result: { number } = {}
	local take = mmin(k, n)
	for i = 1, take do
		result[i] = indices[i]
	end
	return result
end

-- Get hex grid position for a linear index
-- Odd rows are shifted right by half the column spacing
local function getHexPosition(self: ScatterNode, index: number, cx: number, cy: number): (number, number)
	local sx = 0
	if cx > 1 then sx = self.areaWidth / (cx - 1) end
	local sy = 0
	if cy > 1 then sy = self.areaHeight / (cy - 1) end

	local row = mfloor(index / cx)
	local col = index % cx

	local x = col * sx + (row % 2 == 1 and sx * 0.5 or 0)
	local y = row * sy

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
	local totalPoints = friendsNum * 3
	local cx, cy = calcGrid(totalPoints)
	local delay = mmax(0, mfloor(self.delay or self.delayFrames))

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
		self.activeIndices = pickRandomIndices(totalPoints, friendsNum)
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
	local mat = self.mat
	local s = self.pointScale

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
		delayFrames = 3,
		pointScale = 1.0,

		points = {},
		spawnIndex = 0,
		frameCounter = 0,
		mat = late(),
		created = {},
		sharedImage = nil,
		activeIndices = {},
		activeIndicesReady = false,

		init = init,
		advance = advance,
		draw = draw,
	}
end

