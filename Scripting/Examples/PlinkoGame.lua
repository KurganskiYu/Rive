-- Plinko Game
-- A puck drops through a field of pegs and lands in one of 12 slots

local Store = require('Store')

-- ViewModel type for game logic data
type GameLogicVMData = {
  tokenCount: Property<number>,
  scoreTotal: Property<number>,
  gameEnded: Property<boolean>,
  message: Property<string>,
  buttonLabel: Property<string>,
  startTurn: PropertyTrigger,
  turnScore: Property<number>,
  turnTokens: Property<number>,
  turnEnded: PropertyTrigger,
}

-- ViewModel type for store data
type StoreVMData = {
  extraTokenSlotActive: Property<boolean>,
  extraTokenSlotCount: Property<number>,
  superMultiplierCount: Property<number>,
  superMultiplierActive: Property<boolean>,
  multiplierValue: Property<number>,
  superMultiplierCost: Property<number>,
  extraTokenSlotCost: Property<number>,
  storeOpen: Property<boolean>,
}

-- Store item costs and limits (from Store module)
-- local SUPER_MULTIPLIER_COST = Store.items.superMultiplier.cost
-- local SUPER_MULTIPLIER_MAX = Store.items.superMultiplier.maxPurchases :: number
-- local EXTRA_TOKEN_SLOT_COST = Store.items.extraTokenSlot.cost
-- local EXTRA_TOKEN_SLOT_MAX = Store.items.extraTokenSlot.maxPurchases :: number
local BASE_MULTIPLIER_VALUE = Store.BASE_MULTIPLIER_VALUE

local GRAVITY = 900
local BOUNCE_DAMPING = 0.6
local FRICTION = 0.98
local PUCK_RADIUS = 12
local PEG_RADIUS = 4
local NUM_SLOTS = 8
local PEG_ROWS = 14

type PuckState = 'waiting' | 'falling' | 'landed'

type Puck = {
  position: Vector,
  velocity: Vector,
  rotation: number,
  angularVelocity: number,
  state: PuckState,
  artboard: Artboard<PuckVM>?,
  scored: boolean,
}

type PuckVM = {
  puckRotation: Property<number>,
  puckBounce: PropertyTrigger,
}

type PegType = 'normal' | 'multiplier'

type PegVM = {
  pegBounced: PropertyTrigger,
  pegType: Property<string>,
  multiplierValue: Property<number>,
  blink: PropertyTrigger,
}

-- Blink pattern types
export type BlinkPattern =
  'topRightToBottomLeft'
  | 'topLeftToBottomRight'
  | 'centerOut'
  | 'wave'
  | 'spiral'
  | 'random'
  | 'rowByRow'
  | 'columnByColumn'

-- Blink animation state
type BlinkState = {
  active: boolean,
  pattern: BlinkPattern,
  duration: number,
  elapsed: number,
  pegDelays: { [number]: number }, -- delay for each peg index
  pegTriggered: { [number]: boolean }, -- track which pegs have blinked
}

type Peg = {
  position: Vector,
  radius: number,
  active: boolean, -- Whether peg can be collided with
  visible: boolean, -- Whether peg should be drawn
  pegType: PegType,
  artboard: Artboard<PegVM>?,
}

type SlotType = 'normal' | 'addToken'

type SlotVM = {
  scoreValue: Property<number>,
  landed: PropertyTrigger,
  slotType: Property<string>,
}

type Slot = {
  artboard: Artboard<SlotVM>?,
  score: number,
  position: Vector,
  slotType: SlotType,
}

type GameLogicVM = {
  scoreTotal: Property<number>,
  tokenCount: Property<number>,
  gameEnded: Property<boolean>,
  turnEnded: PropertyTrigger,
  startTurn: PropertyTrigger,
  message: Property<string>,
  buttonLabel: Property<string>,
  turnScore: Property<number>,
  turnTokens: Property<number>,
}

type StoreItemVM = {
  id: Property<string>,
  name: Property<string>,
  description: Property<string>,
  cost: Property<number>,
  itemType: Property<string>,
  maxPurchases: Property<number>,
  purchaseCount: Property<number>,
  purchase: PropertyTrigger,
}

type StoreVM = {
  superMultiplierCount: Property<number>,
  extraTokenSlotCount: Property<number>,
  superMultiplierActive: Property<boolean>,
  extraTokenSlotActive: Property<boolean>,
  superMultiplierCost: Property<number>,
  extraTokenSlotCost: Property<number>,
  purchaseSuperMultiplier: PropertyTrigger,
  purchaseExtraTokenSlot: PropertyTrigger,
  multiplierValue: Property<number>,
  storeOpen: Property<boolean>,
  items: PropertyList,
}

local STARTING_TOKENS = 5

-- Random messages shown between rounds
local ROUND_MESSAGES = {
  'Watt a drop!',
  'Shine on!',
  'High voltage victory!',
  'Glow getter!',
  'LIT!',
  'Bright on the money!',
}

local MAX_CONSECUTIVE_HITS = 5

-- Score values for each of the 12 slots (higher in the middle, lower on edges)
local SLOT_SCORES = { 500, 1000, 2000, 5000, 5000, 2000, 1000, 500 }

type Plinko = {
  width: Input<number>,
  height: Input<number>,
  puckArtboard: Input<Artboard<PuckVM>>,
  slotArtboard: Input<Artboard<SlotVM>>,
  pegArtboard: Input<Artboard<PegVM>>,
  gameLogicVM: Input<Data.GameLogicVM>,
  storeVM: Input<Data.StoreVM>,

  pucks: { Puck },
  pucksToAdd: { Puck },
  pegs: { Peg },
  slots: { Slot },
  lastHitPegIndex: { [number]: number }, -- per-puck tracking
  consecutiveHits: { [number]: number }, -- per-puck tracking
  slotWidth: number,
  boardLeft: number,
  boardRight: number,
  boardTop: number,
  boardBottom: number,
  turnEndedFired: boolean, -- track if turnEnded trigger has been fired this turn
  currentTurnScore: number, -- track points earned in the current turn
  currentTurnTokens: number, -- track tokens earned in the current turn
  awaitingFirstTurn: boolean, -- track if game was reset and waiting for first turn to start

  slotPath: Path,

  slotPaint: Paint,
  slotLinePaint: Paint,

  -- Blink pattern state
  blinkState: BlinkState,
  pegRows: number, -- number of peg rows
  pegCols: number, -- max pegs per row
}

-- Check collision between puck and peg, return normal if colliding
local function checkPegCollision(
  puck: Puck,
  peg: Peg,
  puckRadius: number
): Vector?
  local dx = puck.position.x - peg.position.x
  local dy = puck.position.y - peg.position.y
  local dist = math.sqrt(dx * dx + dy * dy)
  local minDist = puckRadius + peg.radius

  if dist < minDist and dist > 0 then
    -- Return normalized collision normal
    return Vector.xy(dx / dist, dy / dist)
  end
  return nil
end

-- Reset all pegs to active and visible
local function resetPegs(self: Plinko)
  for _, peg in ipairs(self.pegs) do
    peg.active = true
    peg.visible = true
  end
end

-- Calculate peg grid position (row, col) from peg index
-- Returns row (0-based), col (0-based), and normalized position (0-1)
local function getPegGridPosition(
  pegIndex: number,
  numSlots: number,
  pegRows: number
): (number, number, number, number)
  -- Reconstruct row and column from the peg index
  local currentIndex = 0
  for row = 0, pegRows - 1 do
    local pegsInRow = (row % 2 == 0) and numSlots or (numSlots - 1)
    if pegIndex <= currentIndex + pegsInRow then
      local col = pegIndex - currentIndex - 1
      -- Normalize positions to 0-1 range
      local normRow = row / math.max(1, pegRows - 1)
      local normCol = col / math.max(1, pegsInRow - 1)
      return row, col, normRow, normCol
    end
    currentIndex = currentIndex + pegsInRow
  end
  return 0, 0, 0, 0
end

-- Calculate delays for each peg based on the blink pattern
local function calculateBlinkDelays(
  self: Plinko,
  pattern: BlinkPattern,
  duration: number
): { [number]: number }
  local delays: { [number]: number } = {}
  local pegCount = #self.pegs

  for i = 1, pegCount do
    local _row, _col, normRow, normCol =
      getPegGridPosition(i, NUM_SLOTS, PEG_ROWS)

    local delay = 0

    if pattern == 'topRightToBottomLeft' then
      -- Diagonal from top-right to bottom-left
      -- Top-right is (row=0, col=max), bottom-left is (row=max, col=0)
      -- Progress = (1 - normCol) + normRow, normalized to 0-1
      local progress = ((1 - normCol) + normRow) / 2
      delay = progress * duration
    elseif pattern == 'topLeftToBottomRight' then
      -- Diagonal from top-left to bottom-right
      local progress = (normCol + normRow) / 2
      delay = progress * duration
    elseif pattern == 'centerOut' then
      -- Radial from center outward
      local centerRow = 0.5
      local centerCol = 0.5
      local dist =
        math.sqrt((normRow - centerRow) ^ 2 + (normCol - centerCol) ^ 2)
      local maxDist = math.sqrt(0.5 ^ 2 + 0.5 ^ 2) -- corner distance
      local progress = dist / maxDist
      delay = progress * duration
    elseif pattern == 'wave' then
      -- Horizontal wave from left to right
      delay = normCol * duration
    elseif pattern == 'spiral' then
      -- Spiral from outside to center
      local centerRow = 0.5
      local centerCol = 0.5
      local dist =
        math.sqrt((normRow - centerRow) ^ 2 + (normCol - centerCol) ^ 2)
      local angle = math.atan2(normRow - centerRow, normCol - centerCol)
      local normalizedAngle = (angle + math.pi) / (2 * math.pi) -- 0 to 1
      local maxDist = math.sqrt(0.5 ^ 2 + 0.5 ^ 2)
      -- Combine distance and angle for spiral effect
      local progress = (1 - dist / maxDist) * 0.7 + normalizedAngle * 0.3
      delay = progress * duration
    elseif pattern == 'random' then
      -- Random delays
      delay = math.random() * duration
    elseif pattern == 'rowByRow' then
      -- Row by row from top to bottom
      delay = normRow * duration
    elseif pattern == 'columnByColumn' then
      -- Column by column from left to right
      delay = normCol * duration
    end

    delays[i] = delay
  end

  return delays
end

-- Start a blink pattern animation
local function startBlinkPattern(
  self: Plinko,
  pattern: BlinkPattern,
  duration: number
)
  self.blinkState = {
    active = true,
    pattern = pattern,
    duration = duration,
    elapsed = 0,
    pegDelays = calculateBlinkDelays(self, pattern, duration),
    pegTriggered = {},
  }
end

-- Update blink pattern (called in advance)
local function updateBlinkPattern(self: Plinko, seconds: number)
  if not self.blinkState.active then
    return
  end

  self.blinkState.elapsed = self.blinkState.elapsed + seconds

  -- Trigger blinks for pegs whose delay has passed
  for i, peg in ipairs(self.pegs) do
    local delay = self.blinkState.pegDelays[i]
    if
      delay
      and not self.blinkState.pegTriggered[i]
      and self.blinkState.elapsed >= delay
    then
      self.blinkState.pegTriggered[i] = true
      if peg.artboard and peg.artboard.data and peg.artboard.data.blink then
        peg.artboard.data.blink:fire()
      end
    end
  end

  -- Check if pattern is complete
  if self.blinkState.elapsed >= self.blinkState.duration then
    -- Fire any remaining pegs that haven't triggered yet
    for i, peg in ipairs(self.pegs) do
      if not self.blinkState.pegTriggered[i] then
        self.blinkState.pegTriggered[i] = true
        if peg.artboard and peg.artboard.data and peg.artboard.data.blink then
          peg.artboard.data.blink:fire()
        end
      end
    end
    self.blinkState.active = false
  end
end

-- Trigger all pegs to blink at once (can be called externally if needed)
local function _blinkAllPegs(self: Plinko)
  for _, peg in ipairs(self.pegs) do
    if peg.artboard and peg.artboard.data and peg.artboard.data.blink then
      peg.artboard.data.blink:fire()
    end
  end
end

-- Randomize which pegs are multiplier pegs
local function randomizePegTypes(self: Plinko)
  local multiplierCount = 3

  -- Reset all pegs to normal
  for _, peg in ipairs(self.pegs) do
    peg.pegType = 'normal'
    if peg.artboard then
      peg.artboard.data.pegType.value = 'normal'
    end
  end

  -- Randomly select pegs to be multipliers
  local pegCount = #self.pegs
  for _ = 1, multiplierCount do
    local randomIndex = math.random(1, pegCount)
    local peg = self.pegs[randomIndex]
    if peg then
      peg.pegType = 'multiplier'
      if peg.artboard then
        peg.artboard.data.pegType.value = 'multiplier'
      end
    end
  end
end

-- Randomize which slots are addToken slots
local function randomizeSlotTypes(self: Plinko)
  -- Reset all slots to normal
  for _, slot in ipairs(self.slots) do
    slot.slotType = 'normal'
    if slot.artboard and slot.artboard.data then
      slot.artboard.data.slotType.value = 'normal'
    end
  end

  -- Determine how many token slots to add (1 base + extra from store)
  local tokenSlotCount = 1
  if self.storeVM and self.storeVM.extraTokenSlotActive then
    if self.storeVM.extraTokenSlotActive.value then
      tokenSlotCount = tokenSlotCount + self.storeVM.extraTokenSlotCount.value
    end
  end

  -- Get available slot indices (excluding first and last slots)
  local slotCount = #self.slots
  local availableIndices: { number } = {}
  for i = 2, slotCount - 1 do
    table.insert(availableIndices, i)
  end

  -- Randomly select slots to be addToken
  for _ = 1, math.min(tokenSlotCount, #availableIndices) do
    local randomPos = math.random(1, #availableIndices)
    local slotIndex = availableIndices[randomPos]
    table.remove(availableIndices, randomPos)

    local slot = self.slots[slotIndex]
    if slot then
      slot.slotType = 'addToken'
      if slot.artboard and slot.artboard.data then
        slot.artboard.data.slotType.value = 'addToken'
      end
    end
  end
end

local ANGULAR_DAMPING = 0.98
local SPIN_FACTOR = 0.02 -- How much horizontal velocity converts to spin on collision

-- Create a new puck at a position
local function createPuck(
  self: Plinko,
  position: Vector,
  velocity: Vector,
  state: PuckState
): Puck
  return {
    position = position,
    velocity = velocity,
    rotation = 0,
    angularVelocity = 0,
    state = state,
    artboard = self.puckArtboard:instance(),
    scored = false,
  }
end

-- Reset to single puck in waiting state at top center (for next round)
local function resetForNextRound(self: Plinko)
  print('resetForNextRound called')
  local centerX = (self.boardLeft + self.boardRight) / 2
  self.pucks = {
    createPuck(
      self,
      Vector.xy(centerX, self.boardTop + PUCK_RADIUS + 10),
      Vector.xy(0, 0),
      'waiting'
    ),
  }
  self.pucksToAdd = {}
  self.lastHitPegIndex = {}
  self.consecutiveHits = {}
  self.turnEndedFired = false
  self.currentTurnScore = 0 -- Reset turn score for new round
  self.currentTurnTokens = 0 -- Reset turn tokens for new round
  resetPegs(self)
  randomizePegTypes(self)
  randomizeSlotTypes(self)
  -- Score persists between rounds, don't reset it
end

-- Set the message and button label
local function setMessageAndButton(
  self: Plinko,
  message: string,
  buttonLabel: string
)
  if self.gameLogicVM then
    if self.gameLogicVM.message then
      self.gameLogicVM.message.value = message
    end
    if self.gameLogicVM.buttonLabel then
      self.gameLogicVM.buttonLabel.value = buttonLabel
    end
  end
end

-- Get a random round message
local function getRandomRoundMessage(): string
  return ROUND_MESSAGES[math.random(1, #ROUND_MESSAGES)]
end

-- Drop all waiting pucks
local function dropPucks(self: Plinko)
  for _, puck in ipairs(self.pucks) do
    if puck.state == 'waiting' then
      puck.velocity = Vector.xy((math.random() - 0.5) * 20, 0)
      puck.state = 'falling'
    end
  end
  -- Quick column blink when dropping
  startBlinkPattern(self, 'spiral', 0.4)
end

-- Spend a token
local function spendToken(self: Plinko)
  if self.gameLogicVM and self.gameLogicVM.tokenCount then
    local currentTokens = self.gameLogicVM.tokenCount.value
    self.gameLogicVM.tokenCount.value = currentTokens - 1
  end
end

-- Update all pegs' multiplier value
local function updatePegsMultiplierValue(self: Plinko, value: number)
  for _, peg in ipairs(self.pegs) do
    if peg.artboard then
      peg.artboard.data.multiplierValue.value = value
    end
  end
end

-- Reset all powerups to their original values
local function resetPowerups(self: Plinko)
  if self.storeVM then
    -- Reset purchase counts
    if self.storeVM.superMultiplierCount then
      self.storeVM.superMultiplierCount.value = 0
    end
    if self.storeVM.extraTokenSlotCount then
      self.storeVM.extraTokenSlotCount.value = 0
    end
    -- Reset active states
    if self.storeVM.superMultiplierActive then
      self.storeVM.superMultiplierActive.value = false
    end
    if self.storeVM.extraTokenSlotActive then
      self.storeVM.extraTokenSlotActive.value = false
    end
    -- Reset multiplier value to base
    if self.storeVM.multiplierValue then
      self.storeVM.multiplierValue.value = BASE_MULTIPLIER_VALUE
    end
    -- Reset costs to original values
    if self.storeVM.superMultiplierCost then
      self.storeVM.superMultiplierCost.value = Store.items.superMultiplier.cost
    end
    if self.storeVM.extraTokenSlotCost then
      self.storeVM.extraTokenSlotCost.value = Store.items.extraTokenSlot.cost
    end
  end
  -- Update pegs to reflect reset multiplier value
  updatePegsMultiplierValue(self, BASE_MULTIPLIER_VALUE)
end

-- Start a completely new game (waits for startTurn to begin first round)
local function startNewGame(self: Plinko)
  -- Reset score and tokens for new game
  if self.gameLogicVM then
    if self.gameLogicVM.scoreTotal then
      self.gameLogicVM.scoreTotal.value = 0
    end
    if self.gameLogicVM.tokenCount then
      self.gameLogicVM.tokenCount.value = STARTING_TOKENS
    end
    if self.gameLogicVM.gameEnded then
      self.gameLogicVM.gameEnded.value = false
    end
  end
  -- Reset all powerups to original values
  resetPowerups(self)
  -- Set initial message and button
  setMessageAndButton(self, 'Let\'s play Blinko!', 'Start Game')
  -- Don't create a puck yet - wait for startTurn trigger
  self.pucks = {}
  self.pucksToAdd = {}
  self.lastHitPegIndex = {}
  self.consecutiveHits = {}
  self.turnEndedFired = false
  self.awaitingFirstTurn = true -- Wait for next startTurn to begin first round
  resetPegs(self)
  randomizePegTypes(self)
  randomizeSlotTypes(self)

  -- Open the store so player can shop before starting
  if self.storeVM and self.storeVM.storeOpen then
    self.storeVM.storeOpen.value = true
  end

  -- Play a celebratory blink pattern for new game
  startBlinkPattern(self, 'centerOut', 0.8)
end

-- Add duplicate pucks at a position (for multiplier peg)
local function addDuplicatePucks(
  self: Plinko,
  position: Vector,
  velocity: Vector
)
  -- Get the number of super multipliers purchased (each adds +1 puck)
  local superMultiplierCount = 0
  if self.storeVM and self.storeVM.superMultiplierCount then
    superMultiplierCount = self.storeVM.superMultiplierCount.value
  end

  -- Base: 2 new pucks (3 total including original)
  -- Each super multiplier adds 1 more puck
  local pucksToSpawn = 2 + superMultiplierCount

  -- Calculate horizontal spread for the pucks
  local spreadWidth = 160 -- Total horizontal spread
  local spacing = spreadWidth / pucksToSpawn

  for i = 1, pucksToSpawn do
    -- Distribute pucks evenly across the spread
    local offsetX = -spreadWidth / 2 + spacing * (i - 0.5)
    table.insert(
      self.pucksToAdd,
      createPuck(
        self,
        Vector.xy(position.x, position.y),
        Vector.xy(velocity.x + offsetX, velocity.y * 0.5),
        'falling'
      )
    )
  end
end

-- Check if all pucks have entered their slots (scored)
local function allPucksScored(self: Plinko): boolean
  for _, puck in ipairs(self.pucks) do
    if not puck.scored then
      return false
    end
  end
  return #self.pucks > 0
end

-- Check if player has tokens remaining
local function hasTokens(self: Plinko): boolean
  if self.gameLogicVM and self.gameLogicVM.tokenCount then
    return self.gameLogicVM.tokenCount.value > 0
  end
  return false
end

-- End the game
local function endGame(self: Plinko)
  if self.gameLogicVM and self.gameLogicVM.gameEnded then
    self.gameLogicVM.gameEnded.value = true
  end
  setMessageAndButton(self, 'Game Over', 'New Game')
end

-- Check if game has ended (no tokens left)
local function isGameEnded(self: Plinko): boolean
  if self.gameLogicVM and self.gameLogicVM.gameEnded then
    return self.gameLogicVM.gameEnded.value
  end
  return false
end

local function init(self: Plinko): boolean
  print('Plinko init called')
  -- Calculate board dimensions with padding
  local padding = 40
  self.boardLeft = padding
  self.boardRight = self.width - padding
  self.boardTop = padding
  self.boardBottom = self.height - padding

  local boardWidth = self.boardRight - self.boardLeft

  self.slotWidth = boardWidth / NUM_SLOTS

  -- Create pegs in staggered rows
  self.pegs = {}
  local pegAreaTop = self.boardTop + 60
  local pegAreaBottom = self.boardBottom - 80

  -- Calculate peg spacing to ensure puck can fit between pegs
  -- The diagonal gap between staggered pegs must be > puck diameter
  local puckDiameter = PUCK_RADIUS * 2

  -- Horizontal spacing is determined by slot width
  local pegHorizontalSpacing = self.slotWidth

  -- Calculate vertical spacing to ensure diagonal gap is large enough
  -- In staggered layout, diagonal distance = sqrt((hSpacing/2)^2 + vSpacing^2)
  -- We need: sqrt((hSpacing/2)^2 + vSpacing^2) - 2*PEG_RADIUS > puckDiameter
  local halfHorizontal = pegHorizontalSpacing / 2
  local minDiagonalDistance = puckDiameter + PEG_RADIUS * 2 + 4
  local minVerticalSpacing = math.sqrt(
    math.max(
      0,
      minDiagonalDistance * minDiagonalDistance
        - halfHorizontal * halfHorizontal
    )
  )

  -- Use the larger of: calculated min spacing or evenly distributed spacing
  local evenRowSpacing = (pegAreaBottom - pegAreaTop) / (PEG_ROWS - 1)
  local pegRowSpacing = math.max(evenRowSpacing, minVerticalSpacing)

  for row = 0, PEG_ROWS - 1 do
    -- Alternate between NUM_SLOTS and NUM_SLOTS-1 pegs per row
    -- Even rows (0, 2, 4...) have full NUM_SLOTS pegs, odd rows have NUM_SLOTS-1
    local pegsInRow = (row % 2 == 0) and NUM_SLOTS or (NUM_SLOTS - 1)
    local rowOffset = (row % 2 == 0) and 0 or (self.slotWidth / 2)

    for col = 0, pegsInRow - 1 do
      local pegX = self.boardLeft + rowOffset + (col + 0.5) * self.slotWidth
      local pegY = pegAreaTop + row * pegRowSpacing

      local pegArtboard = self.pegArtboard:instance()
      pegArtboard.data.pegType.value = 'normal'
      pegArtboard.data.multiplierValue.value = BASE_MULTIPLIER_VALUE

      local peg: Peg = {
        position = Vector.xy(pegX, pegY),
        radius = PEG_RADIUS,
        active = true,
        visible = true,
        pegType = 'normal',
        artboard = pegArtboard,
      }
      table.insert(self.pegs, peg)
    end
  end

  -- Add some multiplier pegs (randomly select a few pegs to convert)
  local multiplierCount = 3
  local pegCount = #self.pegs
  for _ = 1, multiplierCount do
    local randomIndex = math.random(1, pegCount)
    local peg = self.pegs[randomIndex]
    if peg then
      peg.pegType = 'multiplier'
      if peg.artboard then
        peg.artboard.data.pegType.value = 'multiplier'
      end
    end
  end

  -- Create slots with artboard instances
  self.slots = {}
  local slotTop = self.boardBottom - 60
  local slotHeight = self.boardBottom - slotTop
  local slotCenterY = (slotTop + self.boardBottom) / 2
  for i = 1, NUM_SLOTS do
    local slotCenterX = self.boardLeft + (i - 0.5) * self.slotWidth
    local slotArtboard = self.slotArtboard:instance()
    local scoreValue = SLOT_SCORES[i] or 0

    -- Size the artboard to fit the slot dimensions
    slotArtboard.width = self.slotWidth
    slotArtboard.height = slotHeight

    -- Set the scoreValue and slotType in the slot's ViewModel
    slotArtboard.data.scoreValue.value = scoreValue
    slotArtboard.data.slotType.value = 'normal'

    local slot: Slot = {
      artboard = slotArtboard,
      score = scoreValue,
      position = Vector.xy(slotCenterX, slotCenterY),
      slotType = 'normal',
    }
    table.insert(self.slots, slot)
  end

  -- Initialize pucks
  self.pucks = {}
  self.pucksToAdd = {}
  self.lastHitPegIndex = {}
  self.consecutiveHits = {}

  -- Start new game with initial tokens and score
  startNewGame(self)

  -- Listen for startTurn trigger to begin next turn
  print('Setting up startTurn listener, gameLogicVM:', self.gameLogicVM ~= nil)
  if self.gameLogicVM and self.gameLogicVM.startTurn then
    print('startTurn trigger exists, adding listener')
    self.gameLogicVM.startTurn:addListener(function()
      print('startTurn triggered!')
      -- If game has ended, reset game values but don't start playing yet
      if isGameEnded(self) then
        startNewGame(self)
        return
      end

      -- If we just reset the game, this startTurn begins the first round
      if self.awaitingFirstTurn then
        self.awaitingFirstTurn = false
        -- Only start if we have tokens to spend
        if hasTokens(self) then
          -- Close the store when the turn starts
          if self.storeVM and self.storeVM.storeOpen then
            self.storeVM.storeOpen.value = false
          end
          spendToken(self)
          resetForNextRound(self)
        end
        return
      end

      -- Start a new turn if no pucks yet (first round) or all pucks have scored
      if #self.pucks == 0 or allPucksScored(self) then
        -- Only start if we have tokens to spend
        if hasTokens(self) then
          -- Close the store when the turn starts
          if self.storeVM and self.storeVM.storeOpen then
            self.storeVM.storeOpen.value = false
          end
          spendToken(self)
          resetForNextRound(self)
        end
      end
    end)
  end

  -- Initialize store
  if self.storeVM then
    -- Initialize multiplier value
    if self.storeVM.multiplierValue then
      self.storeVM.multiplierValue.value = BASE_MULTIPLIER_VALUE
    end
    -- Open store at game start (before first round)
    if self.storeVM.storeOpen then
      self.storeVM.storeOpen.value = true
    end

    -- Listen for multiplier value changes to update pegs
    -- (StoreLayout handles purchases, but we need to sync peg display)
    if self.storeVM.multiplierValue then
      self.storeVM.multiplierValue:addListener(function()
        local newValue = self.storeVM.multiplierValue.value
        updatePegsMultiplierValue(self, newValue)
      end)
    end
  end

  return true
end

local function advancePuck(
  self: Plinko,
  puck: Puck,
  puckIndex: number,
  seconds: number
)
  -- Only simulate physics when falling
  if puck.state ~= 'falling' then
    return
  end

  -- Apply gravity
  puck.velocity =
    Vector.xy(puck.velocity.x * FRICTION, puck.velocity.y + GRAVITY * seconds)

  -- Apply angular damping
  puck.angularVelocity = puck.angularVelocity * ANGULAR_DAMPING

  -- Update position and rotation
  puck.position = puck.position + puck.velocity * seconds
  puck.rotation = puck.rotation + puck.angularVelocity * seconds

  -- Check peg collisions
  for i, peg in ipairs(self.pegs) do
    if peg.active then
      local normal = checkPegCollision(puck, peg, PUCK_RADIUS)
      if normal then
        -- Fire the pegBounced trigger on the peg
        if peg.artboard and peg.artboard.data then
          peg.artboard.data.pegBounced:fire()
        end

        -- Fire the puckBounce trigger on the puck
        if puck.artboard and puck.artboard.data then
          puck.artboard.data.puckBounce:fire()
        end

        -- Track consecutive hits on same peg
        if self.lastHitPegIndex[puckIndex] == i then
          self.consecutiveHits[puckIndex] = (
            self.consecutiveHits[puckIndex] or 0
          ) + 1
          if self.consecutiveHits[puckIndex] >= MAX_CONSECUTIVE_HITS then
            -- Remove the peg to prevent getting stuck
            peg.active = false
            self.lastHitPegIndex[puckIndex] = nil
            self.consecutiveHits[puckIndex] = 0
          end
        else
          self.lastHitPegIndex[puckIndex] = i
          self.consecutiveHits[puckIndex] = 1
        end

        -- Handle special peg types
        if peg.pegType == 'multiplier' then
          addDuplicatePucks(self, puck.position, puck.velocity)
          peg.active = false -- Disable collision, but keep visible for animation
        end

        -- Push puck out of peg
        local overlap = (PUCK_RADIUS + peg.radius)
          - puck.position:distance(peg.position)
        puck.position = puck.position + normal * (overlap + 1)

        -- Calculate tangent velocity for spin
        local tangent = Vector.xy(-normal.y, normal.x)
        local tangentVelocity = puck.velocity:dot(tangent)

        -- Add spin based on tangent velocity (which side of peg we hit)
        puck.angularVelocity = puck.angularVelocity
          + tangentVelocity * SPIN_FACTOR

        -- Reflect velocity
        local dot = puck.velocity.x * normal.x + puck.velocity.y * normal.y
        puck.velocity = Vector.xy(
          (puck.velocity.x - 2 * dot * normal.x) * BOUNCE_DAMPING,
          (puck.velocity.y - 2 * dot * normal.y) * BOUNCE_DAMPING
        )

        -- Add slight randomness for more interesting bounces
        puck.velocity = puck.velocity + Vector.xy((math.random() - 0.5) * 30, 0)
      end
    end
  end

  -- Wall collisions
  if puck.position.x - PUCK_RADIUS < self.boardLeft then
    puck.position = Vector.xy(self.boardLeft + PUCK_RADIUS, puck.position.y)
    puck.velocity =
      Vector.xy(-puck.velocity.x * BOUNCE_DAMPING, puck.velocity.y)
    -- Add spin when hitting wall
    puck.angularVelocity = puck.angularVelocity - puck.velocity.y * SPIN_FACTOR
  elseif puck.position.x + PUCK_RADIUS > self.boardRight then
    puck.position = Vector.xy(self.boardRight - PUCK_RADIUS, puck.position.y)
    puck.velocity =
      Vector.xy(-puck.velocity.x * BOUNCE_DAMPING, puck.velocity.y)
    -- Add spin when hitting wall
    puck.angularVelocity = puck.angularVelocity + puck.velocity.y * SPIN_FACTOR
  end

  -- Check slot area collisions
  local slotTop = self.boardBottom - 60
  local slotBottom = self.boardBottom - 5

  if puck.position.y + PUCK_RADIUS >= slotTop then
    -- Determine which slot the puck is in
    local slotIndex =
      math.floor((puck.position.x - self.boardLeft) / self.slotWidth)
    slotIndex = math.max(0, math.min(NUM_SLOTS - 1, slotIndex))

    local slotLeftWall = self.boardLeft + slotIndex * self.slotWidth
    local slotRightWall = slotLeftWall + self.slotWidth

    -- Bounce off slot walls
    if puck.position.x - PUCK_RADIUS < slotLeftWall then
      puck.position = Vector.xy(slotLeftWall + PUCK_RADIUS, puck.position.y)
      puck.velocity =
        Vector.xy(-puck.velocity.x * BOUNCE_DAMPING, puck.velocity.y)
      puck.angularVelocity = puck.angularVelocity
        - puck.velocity.y * SPIN_FACTOR
    elseif puck.position.x + PUCK_RADIUS > slotRightWall then
      puck.position = Vector.xy(slotRightWall - PUCK_RADIUS, puck.position.y)
      puck.velocity =
        Vector.xy(-puck.velocity.x * BOUNCE_DAMPING, puck.velocity.y)
      puck.angularVelocity = puck.angularVelocity
        + puck.velocity.y * SPIN_FACTOR
    end

    -- Score and fire landed trigger as soon as puck is fully inside slot area
    if not puck.scored and puck.position.y - PUCK_RADIUS >= slotTop then
      puck.scored = true
      -- slotIndex is 0-based, slots array is 1-based
      local slot = self.slots[slotIndex + 1]
      if slot then
        if slot.slotType == 'addToken' then
          -- addToken slot only increases token count, no score
          if self.gameLogicVM and self.gameLogicVM.tokenCount then
            local currentTokens = self.gameLogicVM.tokenCount.value
            self.gameLogicVM.tokenCount.value = currentTokens + 1
            -- Track turn tokens
            self.currentTurnTokens = self.currentTurnTokens + 1
          end
        else
          -- Normal slot adds to the total score
          if self.gameLogicVM and self.gameLogicVM.scoreTotal then
            local currentScore = self.gameLogicVM.scoreTotal.value
            self.gameLogicVM.scoreTotal.value = currentScore + slot.score
            -- Track turn score
            self.currentTurnScore = self.currentTurnScore + slot.score
          end
        end
        -- Fire the landed trigger on the slot's artboard
        if slot.artboard and slot.artboard.data then
          slot.artboard.data.landed:fire()
        end
      end
    end

    -- Bounce off slot floor
    if puck.position.y + PUCK_RADIUS >= slotBottom then
      puck.position = Vector.xy(puck.position.x, slotBottom - PUCK_RADIUS)
      puck.velocity =
        Vector.xy(puck.velocity.x * FRICTION, -puck.velocity.y * BOUNCE_DAMPING)
      -- Rolling friction on floor - horizontal velocity adds to spin
      puck.angularVelocity = puck.angularVelocity
        + puck.velocity.x * SPIN_FACTOR * 0.5
    end

    -- Check if puck has settled (very low velocity and spin)
    local speed = puck.velocity:length()
    local spinSpeed = math.abs(puck.angularVelocity)
    if
      speed < 5
      and spinSpeed < 1
      and puck.position.y + PUCK_RADIUS >= slotBottom - 10
    then
      puck.velocity = Vector.xy(0, 0)
      puck.angularVelocity = 0
      puck.position = Vector.xy(puck.position.x, slotBottom - PUCK_RADIUS)
      puck.state = 'landed'
    end
  end
end

local function advance(self: Plinko, seconds: number): boolean
  -- Update blink pattern animation
  updateBlinkPattern(self, seconds)

  -- Advance all pucks
  for i, puck in ipairs(self.pucks) do
    advancePuck(self, puck, i, seconds)
    -- Advance the puck's artboard animation
    if puck.artboard then
      puck.artboard:advance(seconds)
    end
  end

  -- Advance all slot artboards
  for _, slot in ipairs(self.slots) do
    if slot.artboard then
      slot.artboard:advance(seconds)
    end
  end

  -- Advance all peg artboards
  for _, peg in ipairs(self.pegs) do
    if peg.artboard then
      peg.artboard:advance(seconds)
    end
  end

  -- Add any new pucks created by multiplier pegs
  for _, newPuck in ipairs(self.pucksToAdd) do
    table.insert(self.pucks, newPuck)
  end
  self.pucksToAdd = {}

  -- Fire turnEnded trigger when all pucks have entered their slots (scored)
  if not self.turnEndedFired and allPucksScored(self) then
    self.turnEndedFired = true
    -- Update turn score in view model
    if self.gameLogicVM and self.gameLogicVM.turnScore then
      self.gameLogicVM.turnScore.value = self.currentTurnScore
    end
    -- Update turn tokens in view model
    if self.gameLogicVM and self.gameLogicVM.turnTokens then
      self.gameLogicVM.turnTokens.value = self.currentTurnTokens
    end
    if self.gameLogicVM and self.gameLogicVM.turnEnded then
      self.gameLogicVM.turnEnded:fire()
    end
    -- End the game if no tokens remain after this turn, otherwise show next round message
    if not hasTokens(self) then
      endGame(self)
      -- Game over blink pattern - dramatic spiral
      startBlinkPattern(self, 'spiral', 1.2)
    else
      setMessageAndButton(self, getRandomRoundMessage(), 'Next Round')
      -- Open the store between rounds
      if self.storeVM and self.storeVM.storeOpen then
        self.storeVM.storeOpen.value = true
      end
      -- Play a turn-end blink pattern based on score
      if self.currentTurnScore >= 10000 then
        -- Big win! Diagonal sweep
        startBlinkPattern(self, 'topRightToBottomLeft', 1.0)
      elseif self.currentTurnScore >= 5000 then
        -- Good score - wave pattern
        startBlinkPattern(self, 'wave', 0.8)
      else
        -- Normal turn - row by row
        startBlinkPattern(self, 'rowByRow', 0.6)
      end
    end
  end

  return true
end

local function update(self: Plinko) end

local function draw(self: Plinko, renderer: Renderer)
  -- Draw all pucks first (behind pegs and slots)
  for _, puck in ipairs(self.pucks) do
    if puck.artboard then
      -- Set rotation via ViewModel property
      puck.artboard.data.puckRotation.value = puck.rotation

      renderer:save()
      -- Translate to puck position, then offset to center artboard
      renderer:transform(
        Mat2D.withTranslation(
          puck.position.x - puck.artboard.width / 2,
          puck.position.y - puck.artboard.height / 2
        )
      )
      puck.artboard:draw(renderer)
      renderer:restore()
    end
  end

  -- Draw slot backgrounds using artboard instances
  for _, slot in ipairs(self.slots) do
    if slot.artboard then
      renderer:save()
      local offsetX = slot.position.x - slot.artboard.width / 2
      local offsetY = slot.position.y - slot.artboard.height / 2
      renderer:transform(Mat2D.withTranslation(offsetX, offsetY))
      slot.artboard:draw(renderer)
      renderer:restore()
    end
  end

  -- Draw slot dividers
  self.slotPath:reset()
  local slotTop = self.boardBottom - 60
  for i = 0, NUM_SLOTS do
    local x = self.boardLeft + i * self.slotWidth
    self.slotPath:moveTo(Vector.xy(x, slotTop))
    self.slotPath:lineTo(Vector.xy(x, self.boardBottom))
  end
  -- Bottom line
  self.slotPath:moveTo(Vector.xy(self.boardLeft, self.boardBottom))
  self.slotPath:lineTo(Vector.xy(self.boardRight, self.boardBottom))
  renderer:drawPath(self.slotPath, self.slotLinePaint)

  -- Draw all pegs on top
  for _, peg in ipairs(self.pegs) do
    if peg.visible and peg.artboard then
      renderer:save()
      renderer:transform(
        Mat2D.withTranslation(
          peg.position.x - peg.artboard.width / 2,
          peg.position.y - peg.artboard.height / 2
        )
      )
      peg.artboard:draw(renderer)
      renderer:restore()
    end
  end
end

-- Check if any puck is waiting
local function anyPuckWaiting(self: Plinko): boolean
  for _, puck in ipairs(self.pucks) do
    if puck.state == 'waiting' then
      return true
    end
  end
  return false
end

local function handlePointerDown(self: Plinko, event: PointerEvent)
  if isGameEnded(self) then
    -- Game is over - do nothing on click, wait for startTurn trigger
    -- (the restart button should fire startTurn to reset values,
    -- then another startTurn to begin playing)
  elseif anyPuckWaiting(self) then
    -- Drop the pucks from current position (spends a token)
    dropPucks(self)
  end
  -- Next turn is now started via the startTurn trigger, not by click
  event:hit()
end

local function handlePointerMove(self: Plinko, event: PointerEvent)
  -- Only follow cursor when waiting to drop
  if anyPuckWaiting(self) then
    -- Constrain to valid drop area (horizontal only, stay at top)
    local x = math.max(
      self.boardLeft + PUCK_RADIUS,
      math.min(self.boardRight - PUCK_RADIUS, event.position.x)
    )
    for _, puck in ipairs(self.pucks) do
      if puck.state == 'waiting' then
        puck.position = Vector.xy(x, self.boardTop + PUCK_RADIUS + 10)
      end
    end
  end
end

return function(): Node<Plinko>
  return {
    width = 500,
    height = 500,
    puckArtboard = late(),
    slotArtboard = late(),
    pegArtboard = late(),
    gameLogicVM = late(),
    storeVM = late(),

    pucks = {},
    pucksToAdd = {},
    pegs = {},
    slots = {},
    lastHitPegIndex = {},
    consecutiveHits = {},
    slotWidth = 0,
    boardLeft = 0,
    boardRight = 0,
    boardTop = 0,
    boardBottom = 0,
    turnEndedFired = false,
    currentTurnScore = 0,
    currentTurnTokens = 0,
    awaitingFirstTurn = true, -- Start in awaiting state until first startTurn

    slotPath = Path.new(),

    slotPaint = Paint.with({ style = 'fill', color = Color.rgb(50, 50, 50) }),
    slotLinePaint = Paint.with({
      style = 'stroke',
      color = Color.rgb(200, 200, 200),
      thickness = 2,
    }),

    -- Blink pattern state
    blinkState = {
      active = false,
      pattern = 'topRightToBottomLeft',
      duration = 1,
      elapsed = 0,
      pegDelays = {},
      pegTriggered = {},
    },
    pegRows = PEG_ROWS,
    pegCols = NUM_SLOTS,

    init = init,
    advance = advance,
    update = update,
    draw = draw,
    pointerDown = handlePointerDown,
    pointerMove = handlePointerMove,
  }
end
