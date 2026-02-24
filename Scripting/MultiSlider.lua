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


	type HandleVM = {
		pressed: Property<boolean>,
	}

	type HandleState = {
		instance: Artboard<HandleVM> | nil,
		y: number,
	}

	type VerticalMultiSlider = {
		-- Inputs
		handleArtboard: Input<Artboard<HandleVM>>,
		sizeY: Input<number>,
		handleSize: Input<number>,
		lineThickness: Input<number>,
		lineColor: Input<Color>,
		hitboxWidth: Input<number>,
		hitboxHeight: Input<number>,
		drawHitbox: Input<boolean>,

		-- MainVM properties
		percent1Prop: Property<number> | nil,
		percent2Prop: Property<number> | nil,
		percent3Prop: Property<number> | nil,
		percent4Prop: Property<number> | nil,
		percent5Prop: Property<number> | nil,
		gapProp: Property<number> | nil,
		
		-- Text props
		textPercent1Prop: Property<number> | nil,
		textPercent2Prop: Property<number> | nil,
		textPercent3Prop: Property<number> | nil,
		textPercent4Prop: Property<number> | nil,
		textPercent5Prop: Property<number> | nil,

		-- State
		context: Context | nil,
		linePath: Path,
		linePaint: Paint,
		debugPath: Path, -- Add debug path to state
		debugPaint: Paint, -- Add debug paint to state
		handles: { HandleState },
		activeHandleIndex: number,
		activePointerId: number,
		dragOffsetY: number,
		width: number,
		height: number,
		centerX: number,
		positionsInitialized: boolean,
	}

	local mabs = math.abs
	local mmax = math.max
	local mmin = math.min

	local function clamp(v: number, a: number, b: number): number
		if v < a then return a end
		if v > b then return b end
		return v
	end

	local function getTrackHeight(self: VerticalMultiSlider): number
		if self.sizeY > 0 then
			return self.sizeY
		end
		return mmax(1, self.height)
	end

	local function getGap(self: VerticalMultiSlider): number
		local h = getTrackHeight(self)
		local base = mmax(0, self.handleSize)
		if h <= 0 then
			return 0
		end
		-- Keep constraints solvable even for short tracks.
		return mmin(base, h / 4)
	end

	local function setAllPressed(self: VerticalMultiSlider, pressedIndex: number)
		for i = 1, #self.handles do
			local inst = self.handles[i].instance
			if inst and inst.data and inst.data.pressed then
				inst.data.pressed.value = (i == pressedIndex)
			end
		end
	end

	local function captureMainVMProps(self: VerticalMultiSlider, context: Context)
		local vm = context:viewModel()
		if not vm then
			return
		end

		self.percent1Prop = vm:getNumber('energy1size')
		self.percent2Prop = vm:getNumber('energy2size')
		self.percent3Prop = vm:getNumber('energy3size')
		self.percent4Prop = vm:getNumber('energy4size')
		self.percent5Prop = vm:getNumber('energy5size')
		self.gapProp = vm:getNumber('gap')
		
		self.textPercent1Prop = vm:getNumber('energy1text')
		self.textPercent2Prop = vm:getNumber('energy2text')
		self.textPercent3Prop = vm:getNumber('energy3text')
		self.textPercent4Prop = vm:getNumber('energy4text')
		self.textPercent5Prop = vm:getNumber('energy5text')
	end

	local function updatePercentages(self: VerticalMultiSlider)
		if #self.handles < 4 then
			return
		end

		-- Retry VM property capture in case VM was not available during init.
		if (not self.percent1Prop or not self.textPercent1Prop) and self.context then
			captureMainVMProps(self, self.context)
		end

		local total = getTrackHeight(self)
		if total <= 0 then
			return
		end

		local h1 = self.handles[1].y
		local h2 = self.handles[2].y
		local h3 = self.handles[3].y
		local h4 = self.handles[4].y

		-- Adjust calculations to account for the gaps at the ends
		-- The effective range starts at 'gap' and ends at 'total - gap'
		local gap = getGap(self)
		local effectiveHeight = total 
		
		-- Raw sizes
		local s1 = h1
		local s2 = h2 - h1
		local s3 = h3 - h2
		local s4 = h4 - h3
		local s5 = effectiveHeight - h4

		-- Standard percentages (size)
		local p1 = (s1 / effectiveHeight) * 100
		local p2 = (s2 / effectiveHeight) * 100
		local p3 = (s3 / effectiveHeight) * 100
		local p4 = (s4 / effectiveHeight) * 100
		local p5 = (s5 / effectiveHeight) * 100

		local gapPercent = (gap / effectiveHeight) * 100

		if self.percent1Prop then self.percent1Prop.value = p1 end
		if self.percent2Prop then self.percent2Prop.value = p2 end
		if self.percent3Prop then self.percent3Prop.value = p3 end
		if self.percent4Prop then self.percent4Prop.value = p4 end
		if self.percent5Prop then self.percent5Prop.value = p5 end
		if self.gapProp then self.gapProp.value = gapPercent end

		-- Text percentages calculation (Adjusted so min size = 0%)
		-- Subtract gap from each raw size, clamp to 0, then re-normalize.
		local a1 = mmax(0, s1 - gap)
		local a2 = mmax(0, s2 - gap)
		local a3 = mmax(0, s3 - gap)
		local a4 = mmax(0, s4 - gap)
		local a5 = mmax(0, s5 - gap)
		
		local adjustedTotal = a1 + a2 + a3 + a4 + a5

		if adjustedTotal > 0 then
			if self.textPercent1Prop then self.textPercent1Prop.value = (a1 / adjustedTotal) * 100 end
			if self.textPercent2Prop then self.textPercent2Prop.value = (a2 / adjustedTotal) * 100 end
			if self.textPercent3Prop then self.textPercent3Prop.value = (a3 / adjustedTotal) * 100 end
			if self.textPercent4Prop then self.textPercent4Prop.value = (a4 / adjustedTotal) * 100 end
			if self.textPercent5Prop then self.textPercent5Prop.value = (a5 / adjustedTotal) * 100 end
		else
			-- Fallback if total is 0 (should rarely happen if sizes > gap)
			if self.textPercent1Prop then self.textPercent1Prop.value = 0 end
		end
	end

	local function solveHandleDrag(self: VerticalMultiSlider, index: number, targetY: number)
		local n = #self.handles
		if n == 0 then
			return
		end

		local gap = getGap(self)
		local top = gap -- Start with a gap at the top
		local bottom = getTrackHeight(self) - gap -- End with a gap at the bottom

		local ys: { [number]: number } = {}
		for i = 1, n do
			ys[i] = self.handles[i].y
		end

		-- 1. Clamp target to safe area
		-- Calculate available space for handles above and below to ensure we don't push them out of world
		local minPos = top + (index - 1) * gap
		local maxPos = bottom - (n - index) * gap
		
		targetY = clamp(targetY, minPos, maxPos)
		ys[index] = targetY

		-- 2. Propagate downwards (force neighbors down if overlapped)
		for i = index + 1, n do
			local limit = ys[i - 1] + gap
			if ys[i] < limit then
				ys[i] = limit
			end
		end

		-- 3. Propagate upwards (force neighbors up if overlapped)
		for i = index - 1, 1, -1 do
			local limit = ys[i + 1] - gap
			if ys[i] > limit then
				ys[i] = limit
			end
		end

		-- 4. Check boundaries and compress back if needed.
		-- Only push back if the STACK actually hit a wall.
		if ys[n] > bottom then
			local shift = ys[n] - bottom
			-- Shift implies we are pushing the whole group up
			ys[n] = bottom
			
			-- Propagate that wall hit upwards only if contact remains
			for i = n - 1, 1, -1 do
				local limit = ys[i + 1] - gap
				if ys[i] > limit then
					ys[i] = limit
				end
			end
		end

		if ys[1] < top then
			ys[1] = top
			-- Propagate that wall hit downwards only if contact remains
			for i = 2, n do
				local limit = ys[i - 1] + gap
				if ys[i] < limit then
					ys[i] = limit
				end
			end
		end

		for i = 1, n do
			self.handles[i].y = ys[i]
		end
	end

	local function initializeHandlePositions(self: VerticalMultiSlider)
		local total = getTrackHeight(self)
		for i = 1, #self.handles do
			self.handles[i].y = total * (i / 5)
		end
		self.positionsInitialized = true
		updatePercentages(self)
	end

	local function init(self: VerticalMultiSlider, context: Context): boolean
		self.context = context
		self.linePath = Path.new()
		self.linePaint = Paint.with({
			style = 'stroke',
			thickness = self.lineThickness,
			color = self.lineColor,
			cap = 'round',
		})
		
		-- Initialize debug drawing tools once
		self.debugPath = Path.new()
		self.debugPaint = Paint.with({
			style = 'fill',
			color = 0x64FF0000, -- 0xAA(100) RR(255) GG(00) BB(00)
		})

		self.handles = {}
		for i = 1, 4 do
			local inst = self.handleArtboard:instance()
			if inst then
				inst.width = self.handleSize
				inst.height = self.handleSize
				if inst.data and inst.data.pressed then
					inst.data.pressed.value = false
				end
			end
			table.insert(self.handles, {
				instance = inst,
				y = 0,
			})
		end

		captureMainVMProps(self, context)
		self.positionsInitialized = false
		self.activeHandleIndex = 0
		self.activePointerId = -1
		self.dragOffsetY = 0

		initializeHandlePositions(self)
		return true
	end

	local function update(self: VerticalMultiSlider)
		self.linePaint.thickness = self.lineThickness
		self.linePaint.color = self.lineColor
		for i = 1, #self.handles do
			local inst = self.handles[i].instance
			if inst then
				inst.width = self.handleSize
				inst.height = self.handleSize
			end
		end

		-- Keep ordering/gaps valid if handleSize or other inputs changed at runtime.
		if #self.handles > 0 then
			solveHandleDrag(self, 1, self.handles[1].y)
			updatePercentages(self)
		end
	end

	local function advance(self: VerticalMultiSlider, seconds: number): boolean
		local needsAdvance = false
		for i = 1, #self.handles do
			local inst = self.handles[i].instance
			if inst and inst:advance(seconds) then
				needsAdvance = true
			end
		end
		return needsAdvance
	end

	local function draw(self: VerticalMultiSlider, renderer: Renderer)
		local trackH = getTrackHeight(self)

		self.linePath:reset()
		self.linePath:moveTo(Vector.xy(self.centerX, 0))
		self.linePath:lineTo(Vector.xy(self.centerX, trackH))
		renderer:drawPath(self.linePath, self.linePaint)

		if self.drawHitbox then
			self.debugPath:reset()
			local hw = self.hitboxWidth
			local hh = self.hitboxHeight
			
			for i = 1, #self.handles do
				local h = self.handles[i]
				local x = self.centerX - (hw * 0.5)
				local y = h.y - (hh * 0.5)

				self.debugPath:moveTo(Vector.xy(x, y))
				self.debugPath:lineTo(Vector.xy(x + hw, y))
				self.debugPath:lineTo(Vector.xy(x + hw, y + hh))
				self.debugPath:lineTo(Vector.xy(x, y + hh))
				self.debugPath:close()
			end

			renderer:drawPath(self.debugPath, self.debugPaint)
		end

		local half = self.handleSize * 0.5
		for i = 1, #self.handles do
			local h = self.handles[i]
			local inst = h.instance
			if inst then
				renderer:save()
				renderer:transform(
					Mat2D.withTranslation(
						self.centerX - half,
						h.y - half
					)
				)
				inst:draw(renderer)
				renderer:restore()
			end
		end
	end

	local function measure(self: VerticalMultiSlider): Vector
		local w = mmax(20, self.handleSize * 2)
		local h = mmax(20, getTrackHeight(self))
		return Vector.xy(w, h)
	end

	local function resize(self: VerticalMultiSlider, size: Vector)
		self.width = size.x
		self.height = size.y
		self.centerX = size.x * 0.5

		if not self.positionsInitialized then
			initializeHandlePositions(self)
		else
			-- Re-run constraints to keep valid ordering when size changes.
			solveHandleDrag(self, 1, self.handles[1].y)
			updatePercentages(self)
		end
	end

	local function pickHandle(self: VerticalMultiSlider, position: Vector): number
		-- Match hit radius to visual size (0.5 * handleSize)
		local halfW = self.hitboxWidth * 0.5
		local halfH = self.hitboxHeight * 0.5
		local best = 0
		local bestDist = 999999

		for i = 1, #self.handles do
			local h = self.handles[i]
			local dx = mabs(position.x - self.centerX)
			local dy = mabs(position.y - h.y)
			
			-- Simple box check with expanded radius
			if dx <= halfW and dy <= halfH then
				if dy < bestDist then
					bestDist = dy
					best = i
				end
			end
		end

		return best
	end

	local function pointerDown(self: VerticalMultiSlider, event: PointerEvent)
		-- If we already have an active pointer, ignore others
		if self.activePointerId ~= -1 and self.activePointerId ~= event.id then
			return
		end

		local idx = pickHandle(self, event.position)
		
		-- Always update active pointer ID on down if we found a handle, 
		-- or if we are clicking empty space to clear selection.
		self.activePointerId = event.id
		
		if idx == 0 then
			self.activeHandleIndex = 0
			self.activePointerId = -1 -- Reset immediately if we missed everything
			self.dragOffsetY = 0
			setAllPressed(self, 0)
			if self.context then
				self.context:markNeedsUpdate()
			end
			return
		end

		self.activeHandleIndex = idx
		self.dragOffsetY = event.position.y - self.handles[idx].y
		setAllPressed(self, idx)

		if self.context then
			self.context:markNeedsUpdate()
		end
	end

	local function pointerMove(self: VerticalMultiSlider, event: PointerEvent)
		if self.activeHandleIndex == 0 then
			return
		end
		if self.activePointerId ~= event.id then
			return
		end
		if self.activeHandleIndex < 1 or self.activeHandleIndex > #self.handles then
			return
		end

		local target = event.position.y - self.dragOffsetY
		solveHandleDrag(self, self.activeHandleIndex, target)
		updatePercentages(self)

		if self.context then
			self.context:markNeedsUpdate()
		end
	end

	local function clearInteraction(self: VerticalMultiSlider)
		self.activeHandleIndex = 0
		self.activePointerId = -1
		self.dragOffsetY = 0
		setAllPressed(self, 0)

		if self.context then
			self.context:markNeedsUpdate()
		end
	end

	local function pointerUp(self: VerticalMultiSlider, event: PointerEvent)
		if self.activePointerId ~= -1 and self.activePointerId ~= event.id then
			return
		end
		clearInteraction(self)
	end

	-- Removing strict pointerExit logic often fixes "stalling" when the mouse slips 
	-- slightly outside the hitbox during a drag.
	local function pointerExit(self: VerticalMultiSlider, event: PointerEvent)
		-- Do not clear interaction on exit. 
		-- We rely on pointerUp (which is global in Rive usually) or just let the drag continue 
		-- even if the pixel is outside the specific bounds, which makes for better UX.
	end

	return function(): Layout<VerticalMultiSlider>
		return {
			init = init,
			update = update,
			advance = advance,
			draw = draw,
			measure = measure,
			resize = resize,
			pointerDown = pointerDown,
			pointerMove = pointerMove,
			pointerUp = pointerUp,
			pointerExit = pointerExit,

			handleArtboard = late(),
			sizeY = 400,
			handleSize = 44,
			lineThickness = 3,
			lineColor = 0xFF9097A3,
			hitboxWidth = 44,
			hitboxHeight = 44,
			drawHitbox = true,

			percent1Prop = nil,
			percent2Prop = nil,
			percent3Prop = nil,
			percent4Prop = nil,
			percent5Prop = nil,
			gapProp = nil,
			
			textPercent1Prop = nil,
			textPercent2Prop = nil,
			textPercent3Prop = nil,
			textPercent4Prop = nil,
			textPercent5Prop = nil,

			context = nil,
			linePath = late(),
			linePaint = late(),
			debugPath = late(),
			debugPaint = late(),
			handles = {},
			activeHandleIndex = 0,
			activePointerId = -1,
			dragOffsetY = 0,
			width = 0,
			height = 0,
			centerX = 0,
			positionsInitialized = false,
		}
	end

