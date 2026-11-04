# Rive Catalog Manager: implementation plan

Date: 2026-11-04

## 1. Direction and decisions

Build a small macOS application around the existing pipeline, not a replacement
for it. Python remains responsible for catalog interpretation and generation;
CSV remains the authoritative animation configuration. Rive provides the
interface and animation; SwiftUI/AppKit provides operating-system capabilities.

Decisions confirmed during this investigation:

- First working iteration: browse, add/edit animations, save CSV, generate the
  catalog, and open a local browser preview.
- Clicking a Rive field opens a native editing popover. Avoid precisely aligned
  native text fields over every Rive field.
- Distinguish **ownership groups** such as Welltory, Personal, and other companies
  from **presentation sets** assembled for particular audiences.
- Presentation sets follow the current animation version by default; optional
  version pinning can be added later.
- Keep catalogs in the same repository for simplicity. Preserve existing
  `selected1/index.html` and `selected2/index.html` URLs.
- Store new ownership/set metadata in a human-editable companion file.
- Do not use or extend the deprecated selected-catalog generator.

This document is a plan, not an implementation of the app or scene changes.

### Implementation progress

The first foundation milestone is implemented:

- [Shared catalog grammar](../catalog_core.py), re-exported by the existing
  generator without changing its CLI behavior.
- [Read-only JSON bridge](../catalog_cli.py): versioned `load`/`validate`
  commands, located diagnostics, raw-row/token preservation, and read-only
  resolution of names.
- [macOS integration prototype](./macOS/): actual catalog rows in a Rive
  component list, search/pagination, row selection, independent checkboxes,
  temporary name-editing popovers, and a separate native animation preview.
- The scene's new `IntegrationHarness` reuses the existing `Project`/`Tag`
  design without prematurely redesigning the full catalog interface.
- `Param` is now registered as a component. The unfinished add form no longer
  shares the row view-model type. Host selection replaces per-row selection
  toggling; display strings distinguish missing metadata from zero values.

Run from the repository root:

```bash
CatalogInterface/macOS/run.sh
# Optional: choose a Python executable explicitly.
CatalogInterface/macOS/run.sh --python /opt/homebrew/bin/python3

python3 -B -m unittest test_catalog_core test_copy_recent
swift test --package-path CatalogInterface/macOS \
  --scratch-path "$HOME/Library/Caches/RiveCatalogManager"
```

The launcher compiles the local scene before opening the app. Native build
products live outside Dropbox: cloud-added Finder metadata caused code-signing
failure when the default build directory was inside this workspace.

**Not implemented yet:** persisted drafts/safe multi-file saves, ownership/set
metadata and migration, the complete add/edit form, live parameter/default
editing, generation from the app, recent-export import, deployment, and iOS sync.
The original full details panel remains a design prototype; the test app uses
an explicit native preview pane rather than a guessed overlay frame. Reload
discards name drafts. Script execution and text-input-library support remain
separate feasibility gates, not verified capabilities of this app.

The measurements and "no Swift app was built" statements below describe the
original planning baseline, before this implementation milestone.

#### Session handoff: 2026-11-04

**Stopping point:** a working read-only foundation, not the full first
edit/save/generate iteration. Phase 0's native binding/gesture/list/preview
integration is established; Phase 1's persisted drafts and recovery are still
pending.

Verified today:

- The real catalog loads **118 entries with no diagnostics**, without changing
  the CSV or names table.
- **23 Python tests** passed, covering shared parsing, raw tokens, name-table
  read-only behavior, identities, validation, and existing ZIP/import behavior.
- **2 native integration tests** passed: actual list creation/mutation,
  independent VM values, draft-name updates, real AppKit mouse gestures,
  exclusive selection, independent checkboxes, one host event per row click,
  rapid preview switching, and separate animation loading.
- The macOS executable builds with Apple runtime **6.29.0**.
- Rive compile verification and inspection both report **no problems**.
- The original generator still re-exports the extracted helpers; its existing
  import/generation-summary tests pass. No real catalog generation, import,
  archive deletion, publishing, or iOS sync was performed.

Implementation details worth preserving:

- Build/test with the external scratch directory shown above. The abandoned
  default `.build` directory in Dropbox is not the working build.
- Native gesture tests must wait for the asynchronously created Metal subview
  and a laid-out window before sending events.
- Keep one host subscription per action property. Event-count verification uses
  the store's counter, not a second subscription to the same trigger stream.
- Cancelled/stale preview operations must not overwrite the current preview's
  error state. The SDK can report cancellation as its own error type.
- All editing is currently temporary. Reload discards draft names; there is no
  CSV save command, and the bridge explicitly rejects writes.

**Small unfinished wiring:** the backend now returns parsed `size_x`/`size_y`
labels. Add them to the Swift DTO and use them in `CatalogStore.updateRows`
instead of splitting the raw size string in Swift. This preserves Python's
case-insensitive/fixed/layout parsing and keeps grammar out of the host.

Recommended order tomorrow:

1. Finish that dimension-label wiring and add its mixed-case/layout regression.
2. Re-run the commands above; launch the prototype and review native editing UX.
3. Implement Phase 1's editable draft and safe save/recovery boundary with
   temporary-directory tests before enabling any real catalog writes.
4. Then wire the full Rive details/add form and the save/generate/local-preview
   loop. Ownership groups/presentation sets follow; publishing/sync stay disabled.

Changes are uncommitted. The working files are the shared core/bridge and Python
tests, the navigation helper and maintained generator, the scene, this plan, and
the `macOS` package/launcher/tests. No other task needs to be started tonight.

## 2. Findings from the current project

### 2.1 Pipeline inventory

| Surface | Existing behavior | Implication for the manager |
|---|---|---|
| [Main generator](../_generate_html.py) | Loads flexible CSV rows, applies defaults, creates detail pages and paginated catalog pages | Reuse its rendering and parsing rather than reproducing them in Swift |
| [Animation table](../_videos.csv) | Three positional fields followed by any number of parameter tokens | Not a fixed-column spreadsheet; use structured parameter records plus preserved raw tokens |
| [Names table](../_videos_names.csv), [navigation helper](../_navigation.py) | Version-independent display names; distinct artboard suffixes for shared files; automatic name-table synchronization | Adding an animation no longer necessarily requires manually inserting a names row; generator already creates blank entries |
| File importing in [the generator](../_generate_html.py#L1264) | Recursively scans an export folder for recent `.riv`/`.zip` files; default age is 300 seconds | Provide explicit file import as well as a compatible recent-export command |
| ZIP importing | Selects exactly one matching unversioned `.riv`, writes renamed copies beside the archive and into `riv`, then deletes the ZIP | Preview the operation and warn about source-side effects; never invoke this merely to load the catalog |
| Preview generation | Uses a sibling `<src>_preview.riv` if available, or the main file when preview dimensions are configured; preview artboard is `preview` | Preview settings are separate from the main artboard; an empty preview-size field does not necessarily mean no preview |
| Web preview | Interactive controls, triggers, layout-aware canvas sizing, external image/font loading, selectable page backgrounds | Browser preview remains the reference test for the generated website |
| [Selected tables](../_videos_selected1.csv), [second set](../_videos_selected2.csv) | Independent copies of animation rows, including older versions and divergent settings | Import them with reconciliation, not as simple membership lists |
| [Old selected generator](../_generate_selected.py) | Explicitly marked deprecated; duplicates older rendering logic | Replace with an output-target option in the maintained generator |
| [iOS sync](../_sync_files.py) | Protects sources referenced by main/selected CSVs, archives other `.riv` files, copies only the main CSV, replaces the app's entire `riv` directory | This is not a harmless copy-only action; add a dry-run and safe apply before exposing it |
| [macOS push script](../push_mac.py) | Stages everything, commits, pushes the current branch; supports `REPO_PATH` | Do not expose it as a selective per-animation publish operation |
| [Server launcher](../server.sh) | Runs Python's HTTP server on port 8000 | Start an app-owned loopback server explicitly; do not source shell configuration |
| [macOS server helper](../server_mac.sh) | Appends an alias to shell configuration rather than starting a server | Do not call it from the application |
| [HTML head](../head.html) | Loads the web runtime from an unversioned CDN URL | Pin a validated web-runtime version when introducing parity tests |

Measured baseline, including nonempty final lines without a trailing newline:

- Main catalog: **118 entries**, **114 distinct source files**; all referenced
  main `.riv` files exist.
- Selected 1: **54 entries**, 51 distinct sources; one missing source,
  `contraHMI_v21.riv`, at [row 55](../_videos_selected1.csv#L55).
- Selected 1 also has a malformed extra `393x852` token at
  [row 15](../_videos_selected1.csv#L15).
- Selected 2: **34 entries**, 34 distinct sources; all main files exist.
- These legacy-set issues should appear in migration review. Do not silently
  omit the rows or repair their meaning by guessing.

### 2.2 CSV and parameter contract to preserve

Current animation-row shape:

```text
src,size,preview,params...
```

`src` is normally a versioned filename stem without `.riv`. There is no separate
CSV version column. Width/height specifications accept numeric dimensions or
`layout` independently, including `393xlayout`, `layoutx393`, and
`layoutxlayout`.

Scalar tokens:

- `sm:` selects the state machine; omitted/empty uses `State Machine 1`.
- `artboard:` selects the main artboard; omission uses `main`.
- `artboard:-` explicitly omits artboard selection and lets the runtime choose.
  Do not collapse this into an omitted CSV token.
- `trigger:` names a trigger. Generated controls try the view model first, then
  a state-machine input.
- `note:` may repeat. Preserve every occurrence and its order.

| Token | Current target and behavior | Editor requirement |
|---|---|---|
| `num:Name(value)` | Legacy state-machine number; fallback UI value is 80 | Distinguish it from a view-model number |
| `bol:Name` | Legacy state-machine boolean; checkbox starts false | Do not promise that a serialized default is honored without extending/test-covering the generator |
| `v_num:Name(value)` | View-model number; fallback UI value is 0 | Native numeric editor; optional range |
| `v_num:Name(current:min-max)` | Range slider; decimal precision determines step | Preserve numeric spelling/precision; validate bounds and current value |
| `v_bol:Name(true/false)` | View-model boolean with supported defaults | Toggle in Rive or edit its configured default |
| `txt:Name("text")` | View-model string | Native text editing; preserve Unicode and CSV quoting |
| `col:Name` | View-model color; current generated UI initializes a random opaque RGB color | Add a color editor, but do not invent persisted default semantics |
| `enum:Name(Default:A\|B\|C)` | View-model enum; options/default come from the token | Edit ordered options and default; distinguish the animation's enum from the UI's parameter-kind enum |
| `img:Name(file.png)` | View-model image loaded from `img`; also participates in external image-asset loading | Select/copy an image, validate dependencies, test generated JS |
| `font:"File.otf"` or `font:Asset(File.otf)` | Referenced font asset loaded from `fonts`; not a numeric/string VM parameter | Separate asset name from filename |
| `list:ListName[num:Field]` | Numeric inner field recognized, but generated code does not edit/populate list data | Preserve and display it; mark list-value editing as not yet implemented |

All ten input prefixes must survive editing even though the current main CSV
does not contain every supported type.

Important limits:

- The current loader reads one physical line at a time. Do not write actual
  embedded newlines in a CSV cell until loader support is intentionally added.
  Multiline native editors can wrap text; rejecting unsupported newline saves
  must produce an understandable validation message.
- Unknown/malformed tokens currently generate warnings and are ignored by
  rendering. The manager must retain them verbatim, expose their status, and
  avoid representing them as successfully supported controls.
- Image handling needs an early browser regression fixture: the catalog JS
  builder does not exclude `img` from its legacy-input lookup path, unlike other
  view-model-only types. Validate and repair this coupled path before claiming
  complete image support.
- Existing external-image asset loading uses the first configured image default
  for image assets. Supporting multiple independently mapped external assets is
  a later explicit extension, not an assumed capability.
- Generated pages contain random color initialization. Golden tests need a
  controlled random seed/fixture, not naive byte comparison.

## 3. Rive prototype assessment

Sources: [scene](./scene.rml), [project configuration](./rive.yaml),
[project instructions](./AGENTS.md). The CLI documentation and schema were used
instead of guessing RML properties.

### 3.1 Existing artboards

| Artboard | Present structure | Required work |
|---|---|---|
| `CatalogInterface` | 934 x 800; group tabs, repeated project list, plus control, four footer buttons, nested details panel | Dynamic group/set navigation, selection, add action, search, scrolling, operation/error states |
| `Project` | Compact row; number, versions, name, size, file size, tag list; selected-state animation | Stable entry identity, open-details action, independent checkbox behavior, better hit targets |
| `Tag` | Small label with eight string-driven color states | Keep generated capability badges separate from user-defined tags |
| `StartAndPreviewButton` | Label/color binding and idle state machine | Click/hover/pressed/disabled behavior and host action |
| `Button` | Reusable label/color binding and idle state machine | Same interaction contract; distinguish different operations |
| `Param` | Parameter badge with nine kind-driven color states | Register as component; add clickable editing affordance and displayed value/error |
| `ProjectDetails` | 300 x 768; black placeholder preview, literal filename/artboard, six fixed parameter components, buttons | Bind selected-entry details and dynamic parameter list; real preview is a separate native runtime view |
| `AddProjectForm` | 578 x 600; background only, empty/default timeline | Implement the form described below; give it a separate form view model |

### 3.2 Existing view models

| Model | Current fields |
|---|---|
| `MainVM` | `projectsList` only |
| `ProjectVM` | `checked`, `selected`, `number`, `name`, `fileName`, `version`, `versionNewer`, `artboard`, `sizeX`, `sizeY`, `fileSize`, `propsList`, `tagsList` |
| `ParameterVM` | `paramName`, `paramType`, `numberProp`, `numberPropMin`, `numberPropMax`, `booleanProp`, `fontProp`, `noteProp` |
| `ButtonVM` | `active`, `pressed`, `hover`, `buttonColor`, `buttonName` |
| `TagVM` | `tag` |
| `ColorsGVM` | 26 global color properties |

The `ParamType` enum currently contains Font, Trigger, Preview, note, File, Enum,
String, Boolean, and Number. It is a presentation taxonomy, not the CSV grammar:
it does not distinguish legacy/view-model numbers or booleans and has no explicit
Color, Image, or List kind.

Observed functional gaps:

1. Main list and row labels already bind to view models; tag repetition works.
2. Only the project-row click listener is implemented. It negates that row's
   `selected` boolean; it does not enforce one selected entry or communicate
   selected details to the host.
3. `checked` is not wired into the visible checkbox interaction.
4. The details panel has no selected-project view model, and its metadata and
   parameters are sample literals/instances.
5. Footer buttons, plus, parameter badges, and detail actions have no listeners
   for their intended operations.
6. There are no local `ScriptAsset`/scripted UI implementations in this scene.
7. A Text Input library definition exists, but no placed input is present in the
   current form. Its existence does not prove native macOS text editing support.
8. `Param` is marked as a component but has no matching `ComponentAsset`.

**A subtle list-design issue:** `AddProjectForm` currently shares `ProjectVM`
with the `Project` row. CLI data documentation explains that component lists
resolve their row artboard through the item view-model type. Give forms and
details their own root VM types so they cannot compete with `Project` as the
row artboard. Do not solve details binding by assigning `ProjectVM` directly to
another root artboard.

### 3.3 Verified baseline versus unverified claims

- Installed CLI: `rive 1.7.0`.
- From this directory, `rive . --verify --format=json` passed.
- `rive inspect . --summary` reported the `Param` component-registration warning,
  even though compile verification reported no warnings.
- `rive . --screenshot --advance=1` rendered the three sample rows, tags, footer,
  and placeholder detail panel. The preview area is blank, as expected.
- Existing focused Python tests passed: `python3 -B -m unittest test_copy_recent`
  ran **11 tests**.
- No Swift application was built. Native list updates, input events, scripting,
  and preview placement still need the Phase 0 runtime spike.
- No generator run against the real catalog, archive deletion, sync, push,
  remote Rive upload, or publication was performed during this investigation.

## 4. Architecture: three small layers

```text
Rive interface                   SwiftUI/AppKit host
lists, cards, buttons    <---->   selection, popovers, file dialogs
transitions, feedback            native Rive preview, browser, clipboard
                                 process lifecycle, operation progress
                                           |
                                 one-shot local Python commands
                                           |
Python catalog core + maintained generator
CSV parsing/writing, metadata, import, generation, validation
                                           |
_videos.csv + _videos_names.csv + companion metadata + assets
```

No Electron application, embedded web interface, database, background web API,
or rewrite of generation in Swift is needed.

### Python boundary

Extract a small shared module, tentatively `catalog_core.py`, for the existing
CSV/token/size and identity helpers. Keep their imports/public behavior available
through [the existing generator](../_generate_html.py) for compatibility.
Keep rendering in that generator; do not perform a wholesale template rewrite.

A small command adapter, tentatively `catalog_cli.py`, accepts JSON on stdin and
returns one versioned JSON response. Proposed commands: `load`, `validate`,
`save`, `import`, `scan-exports`, `generate`, and later `sync-plan`/`sync-apply`.
Responses include errors/warnings with row/field/token locations and an explicit
success flag; operation logs go to stderr. No parsing of friendly console text
to infer success.

Swift launches Python with an explicit executable, argument array, and repository
working directory using `Process`. It does not compose shell commands or import
Python business rules into Swift. Drain stdout/stderr concurrently, handle
nonzero exit, cancellation and startup errors, and serialize repository mutations.
Use bounded progress states initially rather than inventing percentage progress.

The app's generation command must not execute the legacy recent-export scan
implicitly. That scan is a distinct action because it changes files outside the
catalog and may delete archives.

### macOS boundary

Use SwiftUI for the application shell and AppKit for popovers, file dialogs,
clipboard, and browser integration where appropriate. Load the Rive interface
using the official Apple runtime; explicitly retain and bind its VM instances.

The published Apple package manifest inspected during this planning pass points
to runtime 6.29.0 and macOS 13.1. Its tagged source provides the newer `File`,
`Artboard`, `StateMachine`, `Rive`, and `ViewModelInstance` APIs. Prefer these
over copying legacy `RiveViewModel`/property-listener examples. Pin the version
actually tested by Phase 0; do not treat a source declaration as a successful
runtime integration test.

Observe runtime values with the appropriate property/trigger streams. The
modern instance's mutation/dirty stream is not a reliable source for changes
originating exclusively in the runtime or scripts.

For the first development app, use the user's installed Python with an explicit
configuration/availability check and an ordinary local development target.
Bundled Python, App Store sandboxing, notarization, and distribution are later
tasks; silently assuming a sandboxed app can execute arbitrary local tools is
not acceptable.

## 5. Data ownership and persistence

### 5.1 Preserve the existing files

- [Main CSV](../_videos.csv): animation/page configuration.
- [Names CSV](../_videos_names.csv): human-readable names using the existing
  navigation-key algorithm.
- Proposed `_catalog.json`: schema version, stable entry IDs/locators, ownership
  groups, user tags, set definitions, and membership/order.
- Machine-specific export-folder, Python, iOS destination, and server settings:
  local application preferences, not portable catalog metadata.

The companion file is additive. The existing main generator must still work
without it. Missing metadata means an explicit Unassigned ownership group, not
a guess that every animation belongs to Welltory.

### 5.2 Stable identity

An entry is a configured page/artboard, not just a `.riv` file. Four loader
artboards in one source are four entries. Two entries sharing a file should not
overwrite each other's names, set membership, or detail pages.

Keep stable IDs in the companion file. Reconcile CSV edits using unversioned
source plus the artboard selection mode/value; preserve the distinction between
implicit `main`, explicit named artboard, and runtime-default selection.
Ambiguous matches require review rather than row-number guesses.

Do not use a numeric prefix or current list position as identity. Do not use
sanitized page filenames as universal identity: sanitization can collide, and
adding another artboard can change the generator's suffixing behavior.

Names continue to use [the existing helper](../_navigation.py), including its
legacy-name migration and preservation of unused names. Import/update/save must
detect ambiguous name keys before changing files. Changing a source version
must not lose the display name or set memberships.

### 5.3 Safe editing

Maintain an editable draft independently from the saved catalog and independently
from temporary preview values.

- Preserve raw untouched rows, header, unknown tokens, token order, blanks,
  encoding conventions, and line endings where practical.
- Re-serialize only edited rows through Python's CSV writer.
- Validate required fields, safe source/path names, positive fixed dimensions,
  layout modes, defaults, ranges, enum options, asset existence, and duplicate
  page/name keys.
- Detect external changes to CSV/names/metadata before committing a draft.
  Offer reload or explicit reconciliation; never overwrite a changed file.
- Stage writes beside their destinations, retain backups, and use atomic replace
  per file. A multi-file save is not magically atomic: use a small recovery
  journal so interruption between CSV/names/metadata writes is detectable.
- Show the actual proposed diff before destructive or multi-entry operations.

Unknown-token warnings do not discard data; unresolved invalid edits block the
affected save/build with an actionable message.

## 6. Ownership groups and reusable presentation sets

### 6.1 Model and interface

Use one optional ownership group per animation entry initially. Presentation
sets are independent many-to-many membership lists:

```text
All animations
Ownership: Welltory | Personal | Other company...
Presentation sets: Selected 1 | Selected 2 | Client demo...
```

A set has a stable ID, editable name, safe output folder, ordered entry IDs, and
enabled state. Initial members inherit the current saved row/name/defaults.
Filtering the screen must not change what the main catalog publishes.

Preserve the existing tab style, but make its contents data-driven; use a
native popover for overflow/custom set management. Keep `checked` for batch
selection, `selected` for the open details entry, and set membership as separate
states. Selecting a row is not equivalent to including it in a set.

### 6.2 Replace duplicate generators, not duplicate them again

Add an explicit output target and row selection to the maintained generator.
The no-argument CLI path remains unchanged.

For set generation:

1. Resolve ordered members from the authoritative library.
2. Apply only explicit, supported set overrides, if that later feature is added.
3. Render using the same parameter/preview/layout code as the main catalog.
4. Generate navigation containing only that set's members and their names.
5. Write `selected1/index.html`, `selected2/index.html`, or another configured
   folder; pagination and detail pages live inside that folder.
6. Compute asset/link prefixes from the output target, not assumptions about
   `/pages/` being present in the URL.

Audit every relative-path surface: CSS, icon, background-button `.riv`, main and
preview `.riv`, images, fonts, downloads, detail links, pagination, and navigation.
In particular, current image JS derives a prefix by checking for `/pages/`;
that must become an explicit target-derived prefix for set detail pages.

For simplicity, catalogs in this repository share root `riv`, `img`, `fonts`,
and site assets. Do not copy the entire library into every set.

Build into a staging directory and publish only after validating the generated
files. Track owned generated paths in a manifest. Delete stale generated pages
only from that manifest, never every HTML file in a folder or arbitrary assets.
When entries disappear or versions change, this avoids stale public pages and
broken pagination without deleting handwritten files.

Standalone exports or separate repositories can later copy a dependency closure
for just the chosen set, but are not part of the initial architecture.

**A curated set is not access control.** The full repository and asset URLs may
remain publicly reachable. Excluding an animation from a set does not make
company material private.

### 6.3 Migrate the selected CSVs

Provide a migration preview:

- Match rows by logical animation/artboard, ignoring version where appropriate.
- Identify exact matches, older-version matches, changed defaults/artboards,
  selected-only entries, malformed tokens, and missing files.
- Preserve intended display order; the current generators reverse CSV order.
- For divergent rows, offer use-current, preserve configuration for review, or
  import as a distinct library entry where that is valid.
- Do not lose the original tables. Leave them unchanged as migration backups
  until the user validates both generated catalogs.
- Do not keep two competing editable sources indefinitely. After migration,
  membership is owned by `_catalog.json`; legacy selected CSVs can become
  read-only compatibility exports if another consumer still needs them.

Default behavior follows current versions as requested. Version pinning and
per-set parameter overrides are later features. A future pin must retain the
configuration/dependencies that make that version playable, not only a filename.

Update archive/sync retention to include configured sets and future pins before
retiring selected CSVs as retention inputs.

## 7. Scene and host data contract

These are proposed public property names and semantics, not unverified RML code.
Before authoring, resolve each exact type/property with `rive schema`.

| Model | Additions/changes |
|---|---|
| `MainVM` | Groups/sets navigation list, current catalog ID, selected entry ID, search summary, details/form references, dirty/busy/error status, operation button instances |
| `ProjectVM` | Stable `entryId`, ownership label, `hasPreview`, display-ready version labels, validation/update status, `openDetails` and `toggleChecked` triggers |
| `DetailsVM` (new) | Nested selected project, parameter list/reference, displayed metadata, main/preview mode, preview loading/error state, action button instances |
| `FormVM` (new) | Independent draft reference, add/edit mode, validation summary, save eligibility, add-parameter/import/save/cancel button instances |
| `ParameterVM` | Stable parameter ID, exact CSV token kind, binding target, displayed value, optional-default/range flags, text/color/image/enum/list information, validation message, `edit`/`remove` triggers |
| `ButtonVM` | Keep visuals; add `clicked` trigger, enabled/busy state, accessible label |
| `TagVM` | Keep capability badge behavior; use a distinct model/artboard for arbitrary user tags if needed |

Contract rules:

- Python owns persisted configuration. Swift owns application selection and
  drafts. Rive owns transient visual states.
- Host sets `selected` on exactly one visible row; repeated clicking opens the
  same details instead of toggling the only selection off.
- A checkbox hit must not also open/select the row through event bubbling.
- Bind reusable buttons/rows/parameters to their actual per-instance VMs.
  Retain those instances and cancel subscriptions when lists/screens are replaced.
- Observe actions on their originating instance, which already identifies the
  entry/parameter. Do not infer targets from an index that changes after filtering.
- Subscribe to actions before enabling controls; one gesture produces one host
  command. Repeated clicks cannot start overlapping generation/sync/push jobs.
- Provide explicit strings/flags for missing values; do not render an absent
  version as `v0` or an unsupported parameter as a working control.
- Keep preview, trigger, and note metadata distinct from runtime input kinds.
- Keep existing global color bindings. Add Color/Image/List/Unknown badge styles
  and human-readable labels without relying exclusively on color.

Refactor `ProjectDetails` from fixed sample parameters to a component list.
Give `Param` its missing component registration. Keep the form root and details
root distinct from the row's `ProjectVM`, using nested VM references as needed.

### Rive scripting: use it selectively

Start with data binding, converters, state-machine listeners, and host logic.
No scripting is needed merely to dispatch a button or open a native popover.

Use small Luau scripts only where they replace genuinely awkward scene wiring,
such as a custom slider or reusable local interaction/visual behavior. Filtering,
serialization, validation, Git, file copying, and network/deployment checks belong
outside the `.riv`.

Script support and signed-file loading are Phase 0 gates. CLI documentation says
local `.riv` builds are unsigned; files with unsigned scripts are rejected by web
runtimes. Shipping scripted scenes requires an authorized signing workflow.
Do not upload source or use `rive push` as a preview method.
If native signed scripting cannot be verified, keep the first interface
script-free; this does not require abandoning the Rive interface.

## 8. Add/edit animation design

Reuse the current rounded panel, typography, parameter colors, and button
components. Implement `AddProjectForm` as an overlay/sheet with a clear title,
scrollable body, and persistent Save/Cancel footer:

```text
Add animation                                   [Close]

Source       [Choose .riv or .zip]  filename / version
Name         [Displayed name...]   Ownership [Welltory v]
Main         Width [393] Height [layout]
Artboard     [main v]   State machine [State Machine 1 v]
Preview      [Detected file / same source / none]
             Width [...] Height [...]  artboard: preview

Parameters                            [+ Add parameter]
[VM number] percentFrom    5, range 0..100       [Edit] [-]
[VM string] buttonText     Explore patterns...   [Edit] [-]
[Font]      NovemberLC...  File.otf              [Edit] [-]
[Note]      Description...                      [Edit] [-]

Presentation sets [Selected 1] [Client demo] [Choose...]
Validation / unsaved-change message
                                     [Cancel] [Save]
```

Most of this remains Rive: panel layout, displayed values, chips, buttons, badges,
hover/pressed states, empty/error states, and transitions.

Native popovers supply:

- Text/name/path entry, normal selection/copy/paste, undo, IME and accessibility.
- Numeric value plus optional min/max; dimensions offer fixed/layout modes.
- Parameter kind and exact name, with optional runtime-discovered suggestions.
- Enum options/default, booleans, native color picker, image/font file chooser.
- Repeated notes and an advanced raw-token editor for unfamiliar extensions.
- Ownership/set creation and management.

Import first, then discover artboards/state machines/VM properties using the
native runtime if supported. Suggestions are optional and do not replace
manual entry. Runtime introspection cannot reliably supply desired slider ranges,
notes, filenames, or presentation intent.

Save/Cancel must apply to the entire draft. A popover edits that draft, not the
CSV immediately. Escape closes/cancels predictably; Command-S saves after
validation; closing a dirty form requires confirmation.

Do not autosave preview experimentation. The detail panel has separate
**test value** and **configured default** operations, with an explicit command
to promote a test value into the editable configuration.

## 9. Preview and operations UX

### Native preview versus generated-site preview

An arbitrary catalog `.riv` file cannot be assumed to become a nested artboard
inside the interface file. Use a separate native Rive runtime view for the
animation, with its own state machine/VM instance and lifecycle.

Phase 0 should prove a named preview slot can be mapped into host coordinates
under resizing/scaling. Do not assume the Apple runtime exposes that geometry
just because RML has derived bounds properties. If it cannot, use a dedicated
native preview pane adjacent to the Rive detail controls for the first iteration;
avoid brittle hard-coded frame overlays.

The native preview supports selection/loading/error state first; live controls,
fonts/images and main/preview switching follow tested runtime capabilities.
The browser remains authoritative for generated HTML behavior.

Start a loopback-only server with the selected Python executable and explicit
repository root, verify its response, track ownership/PID, and stop only the
process owned by the app. Handle occupied ports without killing another server.
Opening the selected page must use the generator's resolved page stem.

### Separate operations; clarify current labels

| Action | Meaning |
|---|---|
| Import / Scan exports | Copy/extract selected files; never silently choose the highest version |
| Save | Persist validated configuration and name changes |
| Generate | Render main/current/all configured catalogs, explicitly indicating scope |
| Open locally | Open the generated page through the local server |
| Apply newer version | Confirm a matched export and update its shared-file entries consistently |
| Publish | Review changes, commit and push an explicit scope |
| Copy link | Choose local/generated/deployed link; indicate whether deployment was verified |
| Sync iOS | Show source/destination/add/remove/archive dry-run, then confirmed apply |

Replace ambiguous `Update`/`Update All` labels with Generate or Apply newer
version. Disable later-phase Publish/Sync buttons with explanatory status rather
than presenting nonfunctional actions as ready.

Version scanning must recognize filename suffixes without treating the numeric
prefix as unique identity. Show changed file/artboard/parameter compatibility.
Updates to a shared `.riv` must account for all referencing rows, preview files,
names, sets and generated page URLs.

Publishing is later-phase work:

- Main-repository generation can change global indexes/navigation and many
  detail pages; do not promise that a row's Push button only changes one file.
- Review the resulting diff and existing staged changes; never indiscriminately
  stage unrelated work with `git add .`.
- Git success is not deployment success. Track the pushed revision and check
  Pages deployment when feasible, then test the final URL.
- Show queued/building/live/failed or explicitly unverified status.
- Generate links from configurable site base URL and resolved output paths.

For iOS sync, first retain a dry-run and replace full-destination deletion with
a staged, validated copy/swap/backup strategy. Archive retention must include
main entries, sets, previews, and future pins. Missing destination permissions
or assets must fail explicitly. Inspect the iOS consumer before extending its
table schema; its source was not part of this investigation.

## 10. Delivery phases and acceptance gates

### Phase 0: native feasibility and baseline fixtures

Deliver a minimal local macOS test target, not a full manager:

1. Load the current interface and run its default state machine.
2. Bind `MainVM` and create/update several independent `ProjectVM` instances.
3. Prove click -> host action, host -> label change, and native popover -> value.
4. Test dynamic component-list mutation and selected-details handoff.
5. Load a separate animation preview and test resize/coordinate strategy.
6. Prove global colors, enum values, trigger streams and subscription cleanup.
7. If scripting is proposed, independently verify signed scripting on the chosen
   native runtime; otherwise retain the script-free route.

Gate: dynamic rows, one action per gesture, correct instance ownership, native
editing and a usable preview strategy work in a built macOS app. CLI screenshots
alone do not satisfy this gate.

### Phase 1: shared data foundation and backward compatibility

Extract the small catalog core and command adapter; implement read/validate/draft
save with conflict detection and recovery.

Gate:

- A no-op save leaves all existing tables byte-identical.
- Editing a row preserves unrelated rows, unknown tokens, names and Unicode.
- All 118 current entries load, including shared-file artboards.
- Omitted artboard and `artboard:-` remain different.
- Current CLI generation and existing import tests remain functional.
- Errors identify the affected row/field; partial writes are recoverable.

### Phase 2: functional scene and first useful application

Wire reusable controls, selection/checkboxes, dynamic details, the add/edit form,
native popovers, explicit file import, main-catalog generation and browser preview.
Add the companion metadata shape and basic ownership/set assignment controls.

Gate: add one real exported animation with name and parameters, save it, generate
the main website, open its exact local detail URL, change a value, reload, and
verify it persisted. Also update an existing shared-file animation safely.

Known parameters have structured editors. Unknown/list tokens remain visibly
preserved; list-data editing is not advertised as implemented. Validate image
control JS before declaring image support complete.

This is the requested **first working iteration**. Publish and iOS Sync remain
disabled; complete set migration/generation is the next focused milestone.

### Phase 3: reusable presentation catalogs

Implement set creation/order/membership, selected-CSV migration preview, and
output-target rendering through the maintained generator.

Gate:

- Regenerate Selected 1/2 at their existing URLs after resolving migration issues.
- Their navigation/entries include only their membership; all asset links resolve.
- Numeric, layout, font, image, enum and preview behavior matches main rendering.
- Updating a library entry updates following sets without duplicate CSV editing.
- Removing a member cleans owned stale outputs without deleting other files.
- Archived/pinned/selected-only dependencies are protected by retention logic.

### Phase 4: version workflow, publish and deployment

Add export scanning/version comparison, reviewed multi-entry updates, scoped
Git operations, deployment status and deployed-link copying.

Gate: update -> generate -> local check -> reviewed push -> deployment check ->
copy tested URL works, with recoverable errors and no staging of unrelated files.

### Phase 5: iOS sync and polish

Inspect the iOS application's actual CSV/asset requirements, implement safe sync,
then add accessibility/performance polish and optional pins/standalone exports.

Gate: dry-run matches apply; failures leave the previous usable app asset
directory intact; retained catalogs/previews cannot be accidentally archived.

## 11. Verification checklist

### Python/CSV

- Fixtures for all token types, defaults, repeated notes, quoting/commas, Unicode,
  unknown tokens, malformed input, missing assets, empty catalogs and conflicts.
- Sizes: numeric, each one-axis layout mode, both-axis layout, invalid/zero sizes.
- Ranges: decimal precision, negative bounds, reversed bounds, out-of-range value.
- Identity/names: version changes, shared files, sanitized-artboard collisions,
  single-to-multiple-artboard transition, duplicate/ambiguous name keys.
- Import: existing ZIP tests plus explicit selected-file import, overwrite review,
  stale export handling, and interrupted-copy/recovery behavior.
- Generated main/set fixtures: 0, 1, 8 and 9 entries; navigation order,
  pagination, previews, root/set asset prefixes and stale-output cleanup.

### Rive/Swift

- After every scene edit, run `rive . --verify` and
  `rive inspect . --summary` from this directory; inspect the actual output.
- Render screenshots for empty/loading/populated/selected/form/error states.
- Verify button and checkbox hit targets, nested listener behavior, and exactly
  one selected row.
- Add/remove/reorder/filter real list instances and check stable targeting.
- Verify popover commit/cancel, keyboard access, accessible labels and ordinary
  macOS text-input behavior.
- Test window resizing, Retina scale, preview pane positioning and rapid selection.
- Check old subscriptions/runtime instances are released when views change.
- Exercise a 500-entry fixture without reloading the entire scene on each edit;
  use measured responsiveness to decide whether paging/virtualization is needed.

### Browser/end-to-end

- Verify generated output in a browser, not the CLI interface preview.
- Exercise legacy inputs, VM inputs, triggers, enum selection, image/font loading,
  layout resize, main/preview canvases, navigation and background persistence.
- Make load/network/missing-property failures visible; check the browser console.
- Use a pinned web runtime and controlled color fixture for reproducible parity.
- Never run tests that extract/delete real exports, replace the real iOS asset
  folder, or publish changes without explicit approval.

## 12. Open implementation questions and sources

Resolved product choices are in Section 1. Remaining questions are feasibility
gates or later configuration, not reasons to block this plan:

- Runtime support for component-list mutation, signed scripts, and preview-slot
  coordinates must be tested in the small native app.
- Legacy selected-only/different-version rows need migration review.
- Runtime-discovered artboards/parameters can be suggestions; desired defaults
  and list data still require user configuration.
- Python packaging/distribution and the iOS consumer's schema need later work.

Public primary sources checked:

- [Apple runtime README](https://github.com/rive-app/rive-ios/blob/main/README.md):
  macOS, AppKit and SwiftUI support.
- [Package manifest](https://github.com/rive-app/rive-ios/blob/main/Package.swift):
  platform requirement and binary runtime dependency.
- [Tagged ViewModelInstance API](https://github.com/rive-app/rive-ios/blob/6.29.0/Source/Concurrency/DataBinding/ViewModelInstance.swift):
  typed values/streams and explicit instance ownership.
- [Tagged Rive rendering API](https://github.com/rive-app/rive-ios/blob/6.29.0/Source/Concurrency/View/Rive.swift):
  explicit file/artboard/state-machine construction and binding guidance.
- [Tagged property metadata](https://github.com/rive-app/rive-ios/blob/6.29.0/Source/Concurrency/DataBinding/ViewModelProperty.swift):
  runtime property-type discovery.

Direct requests to the hosted Rive documentation failed during investigation.
Public runtime source and locally installed `rive docs data`,
`rive docs publishing`, `rive docs luau/protocols`, and `rive schema` supplied
the usable evidence. No conclusion about native text input or script execution
is based solely on the editor library or a general web-search answer.

**Recommended next action:** implement Phase 0 and Phase 1 before redesigning
the entire scene. Then build the add/edit loop in Phase 2. This proves the
Rive/native/Python boundary early while preserving the working manual pipeline.
