# Catalog Manager: scene-first implementation plan

Updated: 2026-11-04

## Non-negotiable direction

- The application interface is the authored **`CatalogInterface` artboard** in
  [scene.rml](./scene.rml), not a newly designed replacement artboard.
- Preserve its composition, typography, colors, nested `ProjectDetails`,
  prepared buttons, `Project`, `Tag`, and `Param` components.
- Extend those components and their view models. Do not rebuild their visuals
  in SwiftUI/AppKit or add another toolbar/sidebar/dialog system.
- Swift mounts the scene and connects view-model data/actions to CSV/Python/OS
  capabilities. Local UI behavior belongs in Rive listeners/state machines.
- Use Rive scroll layouts, not pagination. Tag values remain `P/F/N/B/S/E/T/n`.
- **No add/edit functionality in the current iteration.**
- **Animation rendering in the black preview screen is deferred.** Wiring the
  selected animation's metadata, parameters and preview controls is current work.

The discarded `CatalogWorkspace`, integration harness, native name editor,
confirmation system and replacement sidebar have been removed. The Python
parsing/persistence foundation is retained; the application does not currently
expose writes.

## Priority 1: make the authored scene functional

Verified: 9 native integration tests and 43 Python tests pass. Rive verification
and inspection are clean. The original layout was rendered and compared with
its pre-wiring screenshot; the authoritative CSV tables were not changed.

### Binding tree

```text
CatalogInterface -> MainVM
  setButtons[]   -> SetButtonVM -> SetButton
  projectsList[] -> ProjectVM   -> Project
    tagsList[]   -> TagVM       -> Tag
  details        -> DetailsVM  -> existing ProjectDetails
    fileName / artboardLabel
    parameters[] -> ParameterVM -> existing Param
    triggerButton / previewButton -> StartButtonVM
    updateButton / pushButton / linkButton -> ButtonVM
  pushAllButton / serverButton / generateAllButton / syncButton -> ButtonVM
```

The added contracts and extracted tab component are in
[bindings.rml](./bindings.rml). The original placements remain in
[scene.rml](./scene.rml).

- `dataBindPathIds` hands each nested placement its instance from the owning VM.
  Do not combine this with an independent `isStateful` instance: it would make
  the displayed component and the host's data diverge.
- Each prepared button owns its click/hover/down/up/exit listeners. Click fires
  its `activate` trigger; exit clears both hover and pressed state.
- Keep one host subscription per trigger. A real pointer gesture must reach the
  same retained VM instance that the component displays.
- `ProjectDetails` listens to its preview button's trigger and toggles
  `DetailsVM.previewMode` **inside Rive**. The host resolves the matching source
  and artboard labels from catalog data.
- Keep `ButtonVM` and `StartButtonVM` distinct: component lists resolve component
  artboards by VM type.
- Authored default/named instances must contain the values used by bindings and
  subscriptions, including empty lists, false booleans, numbers and triggers.
  A property declaration alone did not materialize those values in the tested
  runtime. Verify the resolved data, not just successful compilation.

### Lists and selection

- Mount all catalog rows, using Rive clipping, scroll constraints, elastic
  physics and virtualization.
- Selection and checkboxes remain independent.
- Selection updates the existing filename/artboard labels and replaces the
  parameter list. Never leave sample parameters from the template.
- Each `Param` receives the actual parsed name/type; its existing enum-driven
  color state machine is preserved.
- `configuredDefault`, `rawToken`, and `kind` retain the corresponding CSV data.
  Notes use the existing `note` chip and retain their text in `noteProp`.
- No parameter editing or promotion of preview test values to CSV is exposed.

### Group tabs

- The existing tab design is extracted into a reusable `SetButton` artboard.
  `MainVM.setButtons` supplies All / Welltory / Personal / Crew Mingle.
- All means every animation, **not an ownership assignment**.
- No ownership data exists in the current CSVs. Do not infer it from filenames
  or equate Selected 1/2 presentation tables with ownership.
- `ProjectVM.group` is prepared for manual assignments in Rive. Empty means
  unassigned; `Welltory;Personal` demonstrates multiple runtime memberships.
- Group switching preserves row instances and checkbox state. A group can be
  empty; do not silently substitute the full catalog.
- These manual assignments are currently in-memory only.

### Acceptance gates

- Original 934x800 layout remains visually recognizable, including all existing
  button and screen positions.
- 118 real entries load without modifying source tables.
- Real gestures select rows, check independently, scroll to the final entry,
  switch group tabs and activate the actual nested button VMs.
- Selected filename/artboard/parameters come from the selected CSV row.
- Main/preview toggles the Rive mode and source metadata. Trigger requests carry
  the selected trigger; they do not pretend to play an animation yet.

## Priority 2: connect prepared operation buttons

The buttons' listeners and VM paths are wired. Their external backend operations
are **not implemented in the app** and are dimmed; an attempted action reports
that limitation rather than returning success.

Next, connect one operation at a time:

1. `Update All`: maintained Python generator, without implicit export scanning.
2. `Server`: owned loopback server and exact generated-page opening.
3. Selected `Update` and `Link`: explicitly define generation scope and local
   versus deployed URLs; do not promise a single-file publish.
4. Git Push / Sync: later, reviewed operations with dry-run/scope/confirmation.
   Never stage unrelated changes or delete an entire destination.

Python remains responsible for CSV/token/size grammar and generation.
Preserve the maintained generator's existing CLI behavior and import tests.

## Priority 3: persist group membership

Prefer an additive `_anim_groups.csv`, one entry/group assignment per row,
allowing many groups per animation. Final identity/migration handling must be
tested before writes are enabled.
Include the new file in conflict detection and the recoverable save transaction;
test version changes and shared-artboard entries before committing membership.

Do not add a third names-table column without updating and testing all consumers:
the current navigation code explicitly expects `filename,name`.

The existing `_anim_list.csv` and `_anim_names.csv` remain authoritative for
configuration and names. Selected 1/2 remain presentation sets with their
existing public URLs; they are not ownership groups.

## Priority 4: animation renderer in the authored screen

Do not build another preview pane.

The existing `Screen Display` exports its computed root coordinates through:

```text
MainVM.details.screenX / screenY / screenWidth / screenHeight
```

Measured in the original 934x800 scene: **610, 28, 296, 400**. These are measured
bindings, not constants to hard-code in the host.

The practical fallback is a transparent native Rive rendering view placed over
that exact slot, using the same contain-fit scale/offset as the interface.
Reposition on layout updates; test resizing, Retina, input routing and rapid
selection before enabling it.

The Apple SDK also exposes artboard-valued VM properties. Cross-file dynamic
artboard rendering is a separate feasibility check, not a claimed capability.

A Rive Node script is **not needed for the current details panel**: nested VMs,
component lists, enums and listeners already supply its behavior. Consider
scripting only if the renderer/live-control feasibility test demonstrates a
simpler supported solution. Do not add a Node.js server or upload scenes merely
to preview unsigned scripts.

## Later: add/edit and distribution

Add/edit forms, native text entry, persistent group editing, import, full
presentation-set generation, publishing/deployment verification and iOS sync are
out of the current scene-wiring scope.

The retained JSON bridge supports `load/validate/save/recover`; its save boundary
tracks CSV/names/optional metadata revisions, preserves untouched bytes and uses
locking, atomic per-file replacement, retained backups and an interruption
journal. Keep that tested boundary when editing returns.

## Running and verification

```bash
CatalogInterface/macOS/run.sh
python3 -B -m unittest test_catalog_core test_catalog_persistence test_copy_recent
swift test --package-path CatalogInterface/macOS \
  --scratch-path "$HOME/Library/Caches/RiveCatalogManager"
rive CatalogInterface --verify
rive inspect CatalogInterface --summary
rive CatalogInterface --screenshot --advance=1s
```

Build products stay outside Dropbox. The executable's `@executable_path` runtime
search path lets it find the adjacent Rive framework without opening Xcode.
Screenshots are local checks only; do not use `rive push` for preview.
