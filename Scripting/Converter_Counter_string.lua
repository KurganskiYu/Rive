type ConverterCounter = {
  duration: Input<number>,
  context: Context,
  currentValue: number,
  startValue: number,
  targetValue: number,
  elapsed: number,
  isAnimating: boolean,
}

function init(self: ConverterCounter, context: Context): boolean
  self.context = context
  self.currentValue = 0
  self.startValue = 0
  self.targetValue = 0
  self.elapsed = 0
  self.isAnimating = false
  return true
end

function convert(self: ConverterCounter, input: DataValueNumber): DataValueString
  local dv: DataValueString = DataValue.string()

  local newTarget = input.value
  -- When the input number changes, start a new animation toward it
  if self.targetValue ~= newTarget then
    self.startValue = self.currentValue
    self.targetValue = newTarget
    self.elapsed = 0
    self.isAnimating = true
  end

  -- Request an update loop if we are animating.
  -- This ensures `advance()` and `convert()` continue being called on subsequent frames.
  if self.isAnimating and self.context then
    self.context:markNeedsUpdate()
  end

  -- Output the current intermediate integer as a string
  local currentInt = math.floor(self.currentValue + 0.5)
  dv.value = tostring(currentInt)
  
  return dv
end

function advance(self: ConverterCounter, seconds: number): boolean
  if self.isAnimating then
    self.elapsed = self.elapsed + seconds
    local targetDuration = self.duration
    
    -- Safeguard to prevent division by zero
    if targetDuration <= 0.0 then
      targetDuration = 0.001
    end
    
    local t = self.elapsed / targetDuration
    
    if t >= 1.0 then
      t = 1.0
      self.isAnimating = false
    end
    
    -- Interpolate between the start value and target value
    self.currentValue = self.startValue + (self.targetValue - self.startValue) * t
    
    -- Keep requesting updates until animation completes
    if self.context then
      self.context:markNeedsUpdate()
    end
  end
  return true
end

function reverseConvert(self: ConverterCounter, input: DataValueString): DataValueNumber
  -- When binding back from target to source (not typically used for this one-way counter)
  local dv: DataValueNumber = DataValue.number()
  dv.value = self.targetValue
  return dv
end

-- Return a factory function that builds the converter instance.
return function(): Converter<ConverterCounter, DataValueNumber, DataValueString>
  return {
    duration = 2.0, 
    context = late(),
    currentValue = 0,
    startValue = 0,
    targetValue = 0,
    elapsed = 0,
    isAnimating = false,
    init = init,
    convert = convert,
    reverseConvert = reverseConvert,
    advance = advance,
  }
end
