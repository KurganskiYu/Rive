local Physics = require('Physics')

type SegmentEntry = {
  position: Vector,
  artboard: Artboard<Data.Segment>,
}

type AppleEntry = {
  speed: number,
  position: Vector,
  direction: number,
  artboard: Artboard<Data.Apple>,
}

export type SnakeGame = {
  segment: Input<Artboard<Data.Segment>>,
  addSegment: Input<Trigger>,
  points: Input<Data.Points>,
  snake: Input<Data.Snake>,
  segments: { SegmentEntry },
  apples: { AppleEntry },
  speed: Input<number>,
  accumulator: number,
  fixedStep: Input<number>,
  direction: number,
  startingSegments: Input<number>,
  maxApples: Input<number>,
  apple: Input<Artboard<Data.Apple>>,
  eatIndex: number,
}

local APPLE_RADIUS = 50
local SEGMENT_RADIUS = 50
local APPLE_SPEED_INCREASE = 10
local APPLE_MIN_SPEED = 5
local APPLE_MAX_INITIAL_SPEED = 20
local TURN_SPEED_MULTIPLIER = 12
local EAT_ANIMATION_STEP = 2

-- Add a segment to the centipete
function addSegment(self: SnakeGame)
  -- Create a new instance of the Segment artboard
  local segment = self.segment:instance()
  local entry: SegmentEntry = {
    artboard = segment,
    position = Vector.xy(0, 0),
  }
  if #self.segments == 0 then
    segment.data.segmentType.value = 'Head'
  else
    segment.data.segmentType.value = 'Tail'

    -- As soon as we add a new tail, make the previous item a body element
    if #self.segments > 1 then
      self.segments[#self.segments].artboard.data.segmentType.value = 'Body'
    end
  end

  -- Add this segment to the segments table
  table.insert(self.segments, entry)
end

-- Add a new apple to the scene
-- This only fires when a new game starts. After a new apple is eaten, it gets
-- reused in a different position (positionApple)
function addApple(self: SnakeGame)
  print('add apple')

  -- random direction (in radians)
  local appleDirection = math.random() * 6.28
  -- create a new instance of the Apple artboard
  local apple = self.apple:instance()
  local entry: AppleEntry = {
    artboard = apple,
    position = Vector.xy(0, 0),
    direction = appleDirection,
    -- Give it a random initial speed
    speed = math.random() * APPLE_MAX_INITIAL_SPEED + APPLE_MIN_SPEED,
  }

  positionApple(self, entry)

  table.insert(self.apples, entry)
end

-- Move the apple to a random location
-- This happens when the game starts or when an apple is eaten
function positionApple(self: SnakeGame, entry: AppleEntry)
  -- Add it anywhere on the stage
  local appleX = math.random() * self.snake.stageWidth.value
    - self.snake.stageWidth.value / 2
  local appleY = math.random() * self.snake.stageHeight.value
    - self.snake.stageHeight.value / 2

  --   every time you get an apple, it goes a little faster
  entry.speed = entry.speed + APPLE_SPEED_INCREASE

  -- Update the apple's position with data binding
  entry.artboard.data.x.value = appleX
  entry.artboard.data.y.value = appleY

  -- Trigger the spawn animation with data binding
  entry.artboard.data.spawn:fire()
end

-- Start a new game
-- This fires when the game startts and every time you die
function startGame(self: SnakeGame)
  -- Remove all apples and centipede segments
  self.apples = {}
  self.segments = {}

  -- reset score
  self.snake.score.value = 0

  -- Reset the eat index, which controls the eat animations
  self.eatIndex = -1
end

-- update score when an apple is eaten
local function updateScore(self: SnakeGame, points: number)
  points = math.floor(points + 0.5)
  self.points.pointsX.value = self.segments[1].artboard.data.x.value
  self.points.pointsY.value = self.segments[1].artboard.data.y.value
  self.points.points.value = points
  self.points.showPoints:fire()
  self.snake.score.value = self.snake.score.value + points
end

-- Fired when the apple is eaten
local function eatApple(self: SnakeGame, i: number)
  local currentApple = self.apples[i]
  -- Fire the eatHead trigger
  self.segments[1].artboard.data.eatHead:fire()
  -- Initiates the eat animations which over time will fire on each segment
  self.eatIndex = 0
  -- Fire the screen shake and eat sound
  self.snake.screenShake:fire()
  self.snake.eatSound:fire()

  updateScore(self, currentApple.speed)

  -- Move the eaten apple to another location
  positionApple(self, currentApple)

  addSegment(self)
end

-- Die and restart the game
local function die(self: SnakeGame)
  self.snake.deathSound:fire()
  startGame(self)
end

-- Init (required) fires when the script initializes
function init(self: SnakeGame): boolean
  startGame(self)

  return true
end

-- Determine the new positions and advance the state machines
function advance(self: SnakeGame, seconds: number)
  self.accumulator = self.accumulator + seconds
  -- Move elements once every self.fixedStep seconds
  while self.accumulator >= self.fixedStep do
    -- reset the accumulator
    self.accumulator = self.accumulator - self.fixedStep

    -- Keep adding segments every step
    if #self.segments < self.startingSegments then
      addSegment(self)
    end

    -- Keep adding apples every step
    if #self.apples < self.maxApples then
      addApple(self)
    end

    -- Get the data binding values for the head
    local headData = self.segments[1].artboard.data
    -- The next segment will take the current segment's position and rotation in the next step
    local lastPosition = Vector.xy(headData.x.value, headData.y.value)
    local lastDirection = self.direction

    -- Adjust the head rotation based on the pointer position
    self.direction = self.direction + self.snake.turnRate.value * TURN_SPEED_MULTIPLIER * self.fixedStep

    -- Get the new head position based on speed and direction
    local newHeadX = headData.x.value + self.speed * math.cos(self.direction)
    local newHeadY = headData.y.value + self.speed * math.sin(self.direction)

    local newHeadPosition = Physics.getNewHeadPosition(
      Vector.xy(headData.x.value, headData.y.value),
      self.direction,
      self.speed,
      self.snake.stageWidth.value,
      self.snake.stageHeight.value
    )

    -- Move the apples based on speed and last position
    for i, apple in self.apples do
      local appleData = apple.artboard.data
      local newAppleX = appleData.x.value
        + apple.speed * math.cos(apple.direction)
      local newAppleY = appleData.y.value
        + apple.speed * math.sin(apple.direction)

      local newApplePosition = Physics.getWrappedPosition(
        newAppleX,
        newAppleY,
        self.snake.stageWidth.value,
        self.snake.stageHeight.value
      )

      -- reposition the apple using data binding
      appleData.x.value = newApplePosition.x
      appleData.y.value = newApplePosition.y

      -- Collission detection
      local isHit = Physics.isHit(
        Vector.xy(newHeadX, newHeadY),
        Vector.xy(newAppleX, newAppleY),
        APPLE_RADIUS,
        SEGMENT_RADIUS
      )

      if isHit then
        eatApple(self, i)
      end
    end

    for i, segment in self.segments do
      if i == 1 then
        -- Set the new position and direction of the head
        segment.artboard.data.x.value = newHeadPosition.x
        segment.artboard.data.y.value = newHeadPosition.y
        segment.artboard.data.direction.value = self.direction
      else
        -- set the position and direction of the segment
        local segmentData = segment.artboard.data
        local currentPosition =
          Vector.xy(segmentData.x.value, segmentData.y.value)
        local currentDirection = segmentData.direction.value
        segmentData.x.value = lastPosition.x
        segmentData.y.value = lastPosition.y
        segmentData.direction.value = lastDirection

        -- Fire the eat animation on this segment
        if self.eatIndex == i or self.eatIndex - 1 == i then
          segmentData.eatSegment:fire()
        end

        -- don't check collissions the first 4 segments
        if i > 4 then
          -- collission detection
          local isHit = Physics.isHit(
            Vector.xy(newHeadX, newHeadY),
            Vector.xy(lastPosition.x, lastPosition.y),
            APPLE_RADIUS,
            SEGMENT_RADIUS
          )

          if isHit then
            die(self)
            return true
          end
        end

        -- update the last position, which will be the next segment's position on the next step
        lastPosition = currentPosition
        lastDirection = currentDirection
      end
    end

    if self.eatIndex > -1 and self.eatIndex < #self.segments then
      -- Update the eatIndex += 2 so that it fires 2 segment animations on each frame
      self.eatIndex = self.eatIndex + EAT_ANIMATION_STEP
    else
      self.eatIndex = -1
    end
  end

  -- Advance all state machines every frame, not just ever step
  -- This will allow the animations to go smoothly, even if the segment hasn't moved
  for _, segment in self.segments do
    segment.artboard:advance(seconds)
  end

  for _, apple in self.apples do
    apple.artboard:advance(seconds)
  end
  return true
end

-- Draw (required) all elements every frame
function draw(self: SnakeGame, renderer: Renderer)
  for _, segment in self.segments do
    renderer:save()
    segment.artboard:draw(renderer)
    renderer:restore()
  end

  for _, apple in self.apples do
    renderer:save()
    apple.artboard:draw(renderer)
    renderer:restore()
  end
end

return function(): Node<SnakeGame>
  return {
    init = init,
    draw = draw,
    advance = advance,
    segment = late(),
    segments = {},
    apples = {},
    addSegment = addSegment,
    addApple = addApple,
    speed = 100,
    accumulator = 0,
    fixedStep = 1 / 12,
    startingSegments = 5,
    direction = 0,
    snake = late(),
    maxApples = 3,
    apple = late(),
    eatIndex = -1,
    points = late(),
  }
end
