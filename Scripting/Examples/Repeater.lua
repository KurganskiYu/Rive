type RepeaterEffect = {
  context: Context,
  scaleX: Input<number>,
  scaleY: Input<number>,
  translateX: Input<number>,
  translateY: Input<number>,
  rotation: Input<number>,
  count: Input<number>,
  offset: Input<number>,
}
function init(self: RepeaterEffect, context: Context): boolean
  self.context = context
  return true
end
function update(self: RepeaterEffect, inPath: PathData): PathData
  local outputPath = Path.new()
  local count = self.count
  local translateX = self.translateX
  local translateY = self.translateY
  local scaleX = self.scaleX
  local scaleY = self.scaleY
  local rotationRad = self.rotation * math.pi / 180
  local offset = self.offset
  if count <= 0 then
    return inPath
  end
  local transform = Mat2D.identity()
  transform = transform * Mat2D.withTranslation(translateX, translateY)
  transform = transform * Mat2D.withRotation(rotationRad)
  transform = transform * Mat2D.withScale(scaleX, scaleY)
  local invertTransform = Mat2D.identity()
  local pathTransform = Mat2D.identity()
  -- invertTransform.invert(transform);
  if Mat2D.invert(invertTransform, transform) == false then
    invertTransform = Mat2D.identity()
  end
  for i = 0, math.abs(offset) do
    if offset > 0 then
      pathTransform = pathTransform * transform
    else
      pathTransform = pathTransform * invertTransform
    end
  end
  -- Create each copy with accumulated transformations
  for i = 0, count - 1 do
    pathTransform = pathTransform * transform
    -- Add the path with the current transformation
    outputPath:add(inPath, pathTransform)
  end
  return outputPath
end
function advance(self: RepeaterEffect, seconds: number): boolean
  self.context:markNeedsUpdate()
  return true
end
-- Return a factory function that Rive uses to build the Path Effect instance.
return function(): PathEffect<RepeaterEffect>
  return {
    init = init,
    update = update,
    advance = advance,
    context = late(),
    scaleX = 1,
    scaleY = 1,
    translateX = 0,
    translateY = 0,
    rotation = 0,
    count = 4,
    offset = 0,
  }
end
