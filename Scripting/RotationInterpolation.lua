-- Smooth Rotation Converter
-- Interpolates rotation values smoothly when the source updates at a lower rate than FPS

type SmoothRotation = {
  -- How fast to interpolate (higher = faster, 5-20 is a good range)
  speed: Input<number>,

  -- Internal state
  currentValue: number,
  targetValue: number,
  context: Context?,
}

-- Called once when the script initializes.
function init(self: SmoothRotation, context: Context): boolean
  self.context = context
  self.currentValue = 0
  self.targetValue = 0
  return true
end

function advance(self: SmoothRotation, seconds: number): boolean
  -- Smoothly interpolate current toward target
  local diff = self.targetValue - self.currentValue

  -- Handle angle wrapping (shortest path for rotation in degrees)
  while diff > 180 do
    diff = diff - 360
  end
  while diff < -180 do
    diff = diff + 360
  end

  -- Exponential smoothing (frame-rate independent)
  local t = 1 - math.exp(-self.speed * seconds)
  self.currentValue = self.currentValue + diff * t

  -- Keep current value normalized (0-360 degrees)
  while self.currentValue >= 360 do
    self.currentValue = self.currentValue - 360
  end
  while self.currentValue < 0 do
    self.currentValue = self.currentValue + 360
  end

  -- Keep advancing if we haven't reached target
  local epsilon = 0.01
  if math.abs(diff) > epsilon then
    if self.context then
      self.context:markNeedsUpdate()
    end
  end

  return true
end
 
-- Converts the value when binding from source (ViewModel) to target (Rive property)
function convert(self: SmoothRotation, input: DataValueNumber): DataValueNumber
  -- Store the new target from the view model
  self.targetValue = input.value

  -- Request continuous updates to smooth the transition
  if self.context then
    self.context:markNeedsUpdate()
  end

  -- Return the smoothed current value (converted to radians)
  local output = DataValue.number()
  output.value = self.currentValue * (math.pi / 180)
  return output
end

-- Converts the value when binding from target back to source
function reverseConvert(
  self: SmoothRotation,
  input: DataValueNumber
): DataValueNumber
  -- When setting back to view model, convert radians back to degrees
  local degrees = input.value * (180 / math.pi)
  
  -- Calculate angular difference to detect if this is just feedback from our own output
  local diff = degrees - self.currentValue
  while diff > 180 do diff = diff - 360 end
  while diff < -180 do diff = diff + 360 end

  local output = DataValue.number()

  -- If diff is small, it's the binding loop echoing the lagging current value.
  -- Return the existing targetValue to preserve the JS/ViewModel command.
  if math.abs(diff) < 1.0 then 
    output.value = self.targetValue
  else
    -- Large diff means external change (physics/constraints). Update state to match.
    self.targetValue = degrees
    self.currentValue = degrees
    output.value = degrees
  end
  
  return output 
end

-- Return a factory function that Rive uses to build the Converter instance.
return function(): Converter<SmoothRotation, DataValueNumber, DataValueNumber>
  return {
    speed = 10, -- Default interpolation speed (adjust 5-20 for feel)
    currentValue = 0,
    targetValue = 0,
    context = nil,
    init = init,
    advance = advance,
    convert = convert,
    reverseConvert = reverseConvert,
  }
end
