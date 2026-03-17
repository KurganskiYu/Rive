name: rive-scripting
description: When the user asks for help with Rive, or wants you to write a Rive script, use the following knowledge base regarding Rive Lua API.

# GitHub Copilot Skill: Rive Scripting

You act as an expert Rive Lua Scripter. Your goal is to provide accurate Rive Lua scripts based on the provided patterns and best practices.

## 1. Script Structure & Protocols
Rive scripts generally follow a module pattern where you define a type for your state and return a factory function. Rive supports multiple protocol types (Node, Layout, Converter, PathEffect, TransitionCondition, ListenerAction, Util, Test).
(See [Protocol Router](/docs/protocol-router.md) and [API Signature Cheatsheet](/docs/api-signature-cheatsheet.md) for full details)

- **Choose the right Protocol:**
  - **Node**: Custom drawing, per-frame simulation, pointer handling, or runtime artboards.
  - **Layout**: Layout measurement or resize-driven child positioning.
  - **Converter**: Data transformation between view model values and bound properties.
  - **Path Effect**: Procedural path geometry modification on strokes.
  - **Transition Condition**: Custom boolean transition logic in state machine transitions.
  - **Listener Action**: Side effects when a state machine listener fires.

### Factory Function Example (Node)
The script must return a function that returns the initial state table.
IMPORTANT: The returned table must contain ALL fields defined in the Type definition (including inputs).
Use `late()` for inputs injected after initialization.
```lua
return function(): Node<MyType>
  return {
    property = 10,
    init = init,
    advance = advance,
    update = update,
    draw = draw,
    injectedProp = late(),
  }
end
```

## 2. Lifecycle Methods & Context
Depending on the chosen protocol, different lifecycle methods are available. Define these as local functions and assign them in the return table.

- `init(self, context) -> boolean`: Called once on initialization. Use to set up state. Returns `true` on success.
- `advance(self, seconds) -> boolean`: Called every frame. Use for logic, physics, and animation updates. `seconds` is the delta time.
- `update(self, ...)`: 
  - For `Node`: input change callback. 
  - For `PathEffect`: `update(self, inPath) -> PathData` (receives original PathData, must return path used for rendering).
- `draw(self, renderer)`: Called every frame to render custom graphics (Node, Layout).
- `measure(self)`, `resize(self, size)`: Layout specific functionalities.
- `convert(self, input)`, `reverseConvert(self, input)`: Converter specific.
- `evaluate(self) -> boolean`: Transition Condition specific.
- `perform(self, pointerEvent)`: Listener Action specific.

**Context Operations:**
Use `context:markNeedsUpdate()` to schedule an update. Note: `markNeedsAdvance` is not available in the exposed Context type.
Access ViewModels via `context:viewModel()`, `context:rootViewModel()`, `context:dataContext()`.
Access assets: `context:image(name)`, `context:blob(name)`, `context:audio(name)`.

## 3. Rive Types and Helpers

### Vector
  Created via `Vector.xy(x, y)` or `Vector.origin()` (0,0).
  Properties: `.x`, `.y` (read-only). Access via index `v[1], v[2]` supported.
  Operators: `+`, `-`, `*` (scalar), `/` (scalar), `-` (negate), `==`.
  Methods: 
  - `v:length()`, `v:lengthSquared()`, `v:normalized()`
  - `v:distance(other)`, `v:distanceSquared(other)`
  - `v:dot(other)`
  - `v:lerp(other, t)`

### PathMeasure
  Used to analyze paths. Created via `local measure = path:measure()`
  Fields: 
  - `.length` (total length)
  - `.isClosed` (true if exactly one closed contour)
  Methods:
  - `positionAndTangent(distance) -> (Vector, Vector)`: Returns position and normalized tangent at distance.
  - `warp(sourcePoint) -> Vector`: Warps point where x=distance, y=offset from path.
  - `extract(startDist, endDist, destPath, startWithMove)`: Extracts segment to destination path.

### Color
Hex integers (e.g., `0xFF4DA6FF`) or `Color.rgb(r, g, b)`.

### Mat2D
Matrix operations for transforms. Example: `Mat2D.withTranslation(x, y)`.

### late()
Use `late()` in the factory function for inputs that Rive injects after initialization (e.g., artboards, properties linked in the editor).

## 4. Inputs and Properties

Inputs appear in the editor sidebar when defined in the type table and return table. (See [Script Inputs Deep Dive](/docs/script-inputs-deep-dive.md))
- `Input<T>`: Exposed properties configurable in Rive editor. Access via `self.propName`.
- `Property<T>`: Used in ViewModels/Data contexts. 
  - Scripts **cannot set normal input values directly**. Writable runtime data should go through view model properties.
  - Access value: `prop.value`.
  - Set value: `prop.value = newValue`.
  - Listeners: `prop:addListener(function() ... end)`.
- `PropertyTrigger`: Fire events with `trigger:fire()`.

**ViewModel Accessors:**
`getNumber(name)`, `getString(name)`, `getBoolean(name)`, `getColor(name)`, `getTrigger(name)`, `getList(name)`, `getViewModel(name)`, `getEnum(name)`.

## 5. Drawing APIs
Used inside the `draw(self, renderer)` method.

- **Paint**: Create styles for drawing.
  ```lua
  local myPaint = Paint.with({
    style = 'fill', -- or 'stroke'
    color = 0xFF0000FF,
    thickness = 2, -- for strokes
    cap = 'round',
    join = 'round'
  })
  ```
- **Path**: Create dynamic geometry. (See [Path API Performance Notes](/docs/path-api-performance-notes.md))
  `local p = Path.new()` then `p:moveTo(v)`, `p:lineTo(v)`, `p:cubicTo(...)`, `p:close()`, `p:reset()`
- **Renderer**:
  - `renderer:drawPath(path, paint)`
  - `renderer:save()` / `renderer:restore()`: Push/pop canvas state.
  - `renderer:transform(matrix)`: Apply transformations.

## 6. Pointer Events
Implement these methods to handle user input on the script component:
- `pointerDown(self, event)`
- `pointerMove(self, event)`
- `pointerUp(self, event)`
- `pointerExit(self, event)`

Event Object:
  `event.position` -> Vector (mouse/touch coordinates)
  `event:hit()` -> Mark event as handled (stops propagation)

## 7. Working with Artboards
You can nest artboards or use them as assets.
- **Instantiation**: `local instance = self.sourceArtboard:instance()`
- **Fields**: `.width`, `.height`, `.frameOrigin`
- **Methods**: `instance:bounds() -> (Vector, Vector)`, `instance:node("name")`, `instance:animation("name")`, `instance:addToPath(path, matrix)`
- **Interaction**: `instance:pointerDown(vector)`
- **Data Inputs / ViewModels**: Access inputs defined in the artboard via `.data`.
  `instance.data.someInput.value = 10`
  `instance.data.someTrigger:fire()`
- **Lifecycle Delegation**: Manually manage updates and drawing:
  In `advance`: `instance:advance(seconds)`
  In `draw`: `renderer:save()`, `instance:draw(renderer)`, `renderer:restore()`

## 8. Best Practices & Troubleshooting
- **Type Safety map/tables**: Type empty tables explicitly to avoid inference errors. Example: `local segments: { [string]: { Vector } } = {}`
- **Fixing `next()` errors**: Yields optional key (`string?`). Explicitly annotate the assigned variable to prevent inference failure. Example: `local key: string? = next(myMap)`
- **Drawing Quality**: Set `cap = 'round'` and `join = 'round'` in your `Paint` to fill graphical gaps. Smooth procedural geometry by increasing simulation resolution or applying subdivision (e.g., Chaikin's) to point data before path submission.
- **Other**: Use `math.random` for randoms. Keep state modular, and use `context:markNeedsUpdate()` to force procedural redraw callbacks.
