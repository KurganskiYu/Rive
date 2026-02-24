-- Begin Tile class
local Tile = {}

Tile.__index = Tile

type TileData<T> = {
  artboard: Artboard<Data.TileVM>,
  offsetY: number,
}

type Tile<T = any> = typeof(setmetatable({} :: TileData<T>, Tile))

function Tile.new<T>(artboard: Artboard<Data.TileVM>, offsetY: number): Tile<T>
  local self = {
    artboard = artboard,
    offsetY = offsetY or 0,
  }

  return setmetatable(self, Tile)
end

function Tile.update<T>(self: Tile<T>, dt: number) end

function Tile.advance<T>(self: Tile<T>, dt: number)
  self.artboard.advance(self.artboard, dt)
end
-- End Tile Class

type MasonryLayout = {
  tile: Input<Artboard<Data.TileVM>>,
  columnCount: Input<number>,
  horizontalGap: Input<number>,
  verticalGap: Input<number>,
  scrollVM: Input<Data.ScrollVM>,
  -- private vars
  _width: number,
  _height: number,
  _draggingColumn: number,
  _tiles: { { Tile } },
  _columnWidth: number,
  _hoveredTile: Tile?,
}

function init(self: MasonryLayout): boolean
  update(self)
  return true
end

function advance(self: MasonryLayout, seconds: number): boolean
  -- Hard code the scroll values for now
  local offset = -(self.scrollVM.Scroll.value / 100) * 1500
  local needsAdvance = false
  for i, colTiles in ipairs(self._tiles) do
    -- The further the column from the dragging column, the slower the ease
    local colDiff = math.abs(self._draggingColumn - i) + 1.2
    local y = colTiles[1].offsetY
      + (offset - colTiles[1].offsetY) / (colDiff * colDiff * 3)
    -- Keep advancing until all tiles have settled to within 1 pixel of their target offset
    if math.abs(offset - colTiles[1].offsetY) > 1 then
      needsAdvance = true
    end
    for j, tile in ipairs(colTiles) do
      tile.offsetY = y
      if tile.artboard:advance(seconds) then
        needsAdvance = true
      end
      y += tile.artboard.height + self.verticalGap
    end
  end
  return needsAdvance
end

function update(self: MasonryLayout) end

function draw(self: MasonryLayout, renderer: Renderer)
  local x = 0
  for i, colTiles in ipairs(self._tiles) do
    for j, tile in ipairs(colTiles) do
      renderer:save()
      renderer:transform(Mat2D.withTranslation(x, tile.offsetY))
      tile.artboard:draw(renderer)
      renderer:restore()
    end
    x += self._columnWidth + self.horizontalGap
  end
end

function measure(self: MasonryLayout): Vector
  return Vector.xy(100, 100)
end

function resize(self: MasonryLayout, size: Vector)
  self._width = size.x
  self._height = size.y
  table.clear(self._tiles)
  self._columnWidth = (size.x - (self.columnCount - 1) * self.horizontalGap)
    / self.columnCount
  for i = 1, self.columnCount do
    local colTiles: { Tile } = {}
    local totalHeight = 0
    local index = 0
    repeat
      local tileArtboard = self.tile:instance()
      tileArtboard.data.soloMode.value = math.floor(math.random() * 4)
      local height = math.random(100, 200)
      tileArtboard.width = self._columnWidth
      tileArtboard.height = height
      tileArtboard.data.Column.value = i
      local tile = Tile.new(tileArtboard, 0)
      totalHeight += height + self.verticalGap
      table.insert(colTiles, tile)
      index += 1
    until totalHeight >= size.y
    table.insert(self._tiles, colTiles)
  end
end

function pointerDown(self: MasonryLayout, event: PointerEvent)
  if self._hoveredTile ~= nil then
    self._draggingColumn = math.floor(
      event.position.x / (self._columnWidth + self.horizontalGap)
    ) + 1
    
    -- Only pass pointer down to the hovered tile
    local col = math.floor(
      event.position.x / (self._columnWidth + self.horizontalGap)
    ) + 1
    local x = (col - 1) * (self._columnWidth + self.horizontalGap)
    local localPos = Vector.xy(
      event.position.x - x,
      event.position.y - self._hoveredTile.offsetY
    )
    local localEvent = PointerEvent.new(event.id, localPos)
    self._hoveredTile.artboard:pointerDown(localEvent)
  end
end

function pointerMove(self: MasonryLayout, event: PointerEvent)
  self._hoveredTile = getHoveredTile(self, event)
  
  -- Pass pointer move only to visible tile artboards so eyes can follow the mouse
  local x = 0
  for i, colTiles in ipairs(self._tiles) do
    for j, tile in ipairs(colTiles) do
      -- Skip tiles that are not visible
      local tileBottom = tile.offsetY + tile.artboard.height
      if tileBottom < 0 or tile.offsetY > self._height then
        continue
      end
      -- Convert global position to local tile position
      local localPos = Vector.xy(
        event.position.x - x,
        event.position.y - tile.offsetY
      )
      local localEvent = PointerEvent.new(event.id, localPos)
      tile.artboard:pointerMove(localEvent)
    end
    x += self._columnWidth + self.horizontalGap
  end
end

function getHoveredTile(self: MasonryLayout, event: PointerEvent): Tile?
  if
    event.position.x >= 0
    and event.position.x <= self._width
    and event.position.y >= 0
    and event.position.y <= self._height
  then
    local col = math.floor(
      event.position.x / (self._columnWidth + self.horizontalGap)
    ) + 1
    local colTiles = self._tiles[col]
    for i, tile in ipairs(colTiles) do
      if
        event.position.y >= tile.offsetY
        and event.position.y <= tile.offsetY + tile.artboard.height
      then
        return tile
      end
    end
  end
  return nil
end

function pointerUp(self: MasonryLayout, event: PointerEvent)
  -- Only pass pointer up to hovered tile if any
  if self._hoveredTile ~= nil then
    local col = math.floor(
      event.position.x / (self._columnWidth + self.horizontalGap)
    ) + 1
    local x = (col - 1) * (self._columnWidth + self.horizontalGap)
    local localPos = Vector.xy(
      event.position.x - x,
      event.position.y - self._hoveredTile.offsetY
    )
    local localEvent = PointerEvent.new(event.id, localPos)
    self._hoveredTile.artboard:pointerUp(localEvent)
  end
end

function pointerExit(self: MasonryLayout, event: PointerEvent)
  -- Only pass pointer exit to hovered tile if any
  if self._hoveredTile ~= nil then
    local col = math.floor(
      event.position.x / (self._columnWidth + self.horizontalGap)
    ) + 1
    local x = (col - 1) * (self._columnWidth + self.horizontalGap)
    local localPos = Vector.xy(
      event.position.x - x,
      event.position.y - self._hoveredTile.offsetY
    )
    local localEvent = PointerEvent.new(event.id, localPos)
    self._hoveredTile.artboard:pointerExit(localEvent)
  end
  self._hoveredTile = nil
end

return function(): Layout<MasonryLayout>
  return {
    init = init,
    advance = advance,
    update = update,
    draw = draw,
    measure = measure,
    pointerDown = pointerDown,
    pointerMove = pointerMove,
    pointerUp = pointerUp,
    pointerExit = pointerExit,
    resize = resize,
    tile = late(),
    columnCount = 3,
    horizontalGap = 20,
    verticalGap = 10,
    scrollVM = late(),
    _width = 0,
    _height = 0,
    _draggingColumn = 1,
    _tiles = {},
    _columnWidth = 0,
    _hoveredTile = nil,
  }
end
