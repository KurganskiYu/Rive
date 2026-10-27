import os
import csv
import re
from decimal import Decimal
from functools import lru_cache
import shutil
import time
import random
import json
from html import escape as html_escape

script_dir = os.path.dirname(os.path.abspath(__file__))
csv_path = os.path.join(script_dir, "_videos.csv")
output_html = os.path.join(script_dir, "index.html")
head_html_path = os.path.join(script_dir, "head.html")
pages_dir = os.path.join(script_dir, "pages")
os.makedirs(pages_dir, exist_ok=True)

# Cache file reads
@lru_cache(maxsize=2)
def get_html_head(is_root=True):
    with open(head_html_path, "r", encoding="utf-8") as head_file:
        html_head = head_file.read()
    if not is_root:
        html_head = html_head.replace('href="RiveIcon2.svg"', 'href="../RiveIcon2.svg"')
    return html_head

# NEW: Helper to inject the BG button on every page
def get_bg_button_html(is_root=True):
    riv_path = "bg_button.riv" if is_root else "../bg_button.riv"
    # CSS for top-right fixed position
    html = f'''
    <div style="position:fixed; top:10px; right:10px; z-index:9999; display:flex; flex-direction:column; align-items:center;">
        <canvas id="bg_button_canvas" width="80" height="80"></canvas>
    </div>
    <script>
      (function() {{
        function updatePageBg(mode) {{
            const body = document.body;
            const label = document.getElementById("bg_debug_label");
            if (label) label.textContent = "bg: " + mode;
            console.log("[BG] updatePageBg called with mode:", mode);
            if (mode === 1) {{
                // Checkered pattern
                body.style.backgroundColor = "#000000";
                body.style.backgroundImage =
                    "repeating-conic-gradient(#0f0f0f 0% 25%, transparent 0% 50%)";
                body.style.backgroundSize = "20px 20px";
                body.style.backgroundPosition = "";
            }} else if (mode === 2) {{
                // Solid black
                body.style.backgroundColor = "#000000";
                body.style.backgroundImage = "none";
                body.style.backgroundSize = "";
                body.style.backgroundPosition = "";
            }} else if (mode === 3) {{
                // Solid dark gray
                body.style.backgroundColor = "#121212";
                body.style.backgroundImage = "none";
                body.style.backgroundSize = "";
                body.style.backgroundPosition = "";
            }}
        }}

        // Apply stored background immediately (before Rive loads)
        let storedBg = localStorage.getItem("page_bg_mode");
        if (storedBg) {{
            updatePageBg(parseInt(storedBg));
        }}

        const bgRive = new rive.Rive({{
          src: "{riv_path}",
          canvas: document.getElementById("bg_button_canvas"),
          autoplay: true,
          artboard: "main",
          autoBind: true,
          stateMachines: "State Machine 1",
          onLoad: () => {{
            bgRive.resizeDrawingSurfaceToCanvas();
            console.log("[BG] Rive loaded");
            const vmi = bgRive.viewModelInstance;
            console.log("[BG] viewModelInstance:", vmi);
            if (vmi) {{
                const bgNum = vmi.number("bgNum");
                console.log("[BG] bgNum property:", bgNum);
                if (bgNum) {{
                    // Initialize based on current stored state or default
                    let storedBg = localStorage.getItem("page_bg_mode");
                    let mode = storedBg ? parseInt(storedBg) : 1;
                    bgNum.value = mode;
                    updatePageBg(mode);
                    console.log("[BG] Initial mode set to:", mode, "bgNum.value:", bgNum.value);

                    // Listen for changes from Rive
                    bgNum.onValueChanged = (val) => {{
                        console.log("[BG] onValueChanged fired:", val);
                        updatePageBg(val);
                        localStorage.setItem("page_bg_mode", String(val));
                    }};

                    // Polling fallback: check bgNum.value periodically
                    let lastVal = bgNum.value;
                    setInterval(() => {{
                        const cur = bgNum.value;
                        if (cur !== lastVal) {{
                            console.log("[BG] poll detected change:", lastVal, "->", cur);
                            lastVal = cur;
                            updatePageBg(cur);
                            localStorage.setItem("page_bg_mode", String(cur));
                        }}
                    }}, 200);
                }}
            }}
          }} }}); 
      }})();
    </script>
    '''
    return html

html_foot = """
    </div>
</body>
</html>
"""

SCALE_TO_200PX = True
ANIMATIONS_PER_PAGE = 8

LAYOUT_KEYWORD = "layout"
LAYOUT_PLACEHOLDER_PX = 300  # initial canvas size on an auto axis, replaced once the Rive file loads

def parse_size_spec(size_str):
    """Parse `WxH`. Either side may be `layout` to let the Rive layout (Fit.Layout) decide
    that dimension, e.g. `393xlayout` (fixed width, auto height), `layoutx393`
    (auto width, fixed height) or `layoutxlayout` (both auto)."""
    spec = {"width": 0, "height": 0, "auto_w": False, "auto_h": False}
    if not size_str:
        return spec
    parts = size_str.lower().split('x')
    if len(parts) != 2:
        return spec
    values = []
    for part in parts:
        part = part.strip()
        if part == LAYOUT_KEYWORD:
            values.append(None)
            continue
        try:
            values.append(int(part))
        except ValueError:
            return spec
    spec["auto_w"] = values[0] is None
    spec["auto_h"] = values[1] is None
    spec["width"] = LAYOUT_PLACEHOLDER_PX if spec["auto_w"] else values[0]
    spec["height"] = LAYOUT_PLACEHOLDER_PX if spec["auto_h"] else values[1]
    return spec

def is_layout(ctx):
    return bool(ctx.get("auto_w") or ctx.get("auto_h"))

def size_label(ctx):
    w = "auto" if ctx.get("auto_w") else f'{ctx["width"]}px'
    h = "auto" if ctx.get("auto_h") else f'{ctx["height"]}px'
    return f'{w} × {h}' + (" (layout)" if is_layout(ctx) else "")

def canvas_attrs(ctx, element_id):
    attrs = f'id="{element_id}" width="{ctx["width"]}" height="{ctx["height"]}"'
    if is_layout(ctx):
        attrs += ' class="layout-canvas"'
        if ctx.get("auto_w"):
            attrs += ' data-auto-w'
        if ctx.get("auto_h"):
            attrs += ' data-auto-h'
    return attrs

def control_width_for(ctx):
    """Width of slider controls; unknown (None) when the width is decided by the layout."""
    return None if ctx.get("auto_w") else ctx["width"]

def catalog_canvas_size(row):
    """(width, height, layout_scale_factor) of a catalog canvas.
    For layout canvases the fixed axis is scaled to 200px through layoutScaleFactor."""
    if not is_layout(row):
        w, h = scale_dimensions(row["width"], row["height"])
        return w, h, 1.0
    if row["auto_w"] and row["auto_h"]:
        return row["width"], row["height"], 1.0
    fixed = row["height"] if row["auto_w"] else row["width"]
    if not SCALE_TO_200PX or not fixed:
        return row["width"], row["height"], 1.0
    scale = 200 / fixed
    if row["auto_w"]:
        return row["width"], 200, scale
    return 200, row["height"], scale

AUTO_SIZE_LAYOUT_JS = """
// Fit.Layout: the fixed axis keeps its CSS size, while an `auto` axis follows the size
// the Rive layout reports through bounds (in artboard units, hence the scale factor).
function autoSizeLayoutCanvas(riveInstance, canvas, autoW, autoH, scale) {
  const sync = (force) => {
    const b = riveInstance.bounds;
    let changed = false;
    if (autoW) {
      const w = (b.maxX - b.minX) * scale;
      if (w > 0 && Math.abs(w - (parseFloat(canvas.style.width) || 0)) > 0.5) {
        canvas.style.width = w + "px";
        changed = true;
      }
    }
    if (autoH) {
      const h = (b.maxY - b.minY) * scale;
      if (h > 0 && Math.abs(h - (parseFloat(canvas.style.height) || 0)) > 0.5) {
        canvas.style.height = h + "px";
        changed = true;
      }
    }
    if (changed || force === true) riveInstance.resizeDrawingSurfaceToCanvas();
    requestAnimationFrame(() => sync());
  };
  // Start from the artboard's own size so a non-hugging artboard keeps its designed size.
  riveInstance.resetArtboardSize();
  sync(true);
  window.addEventListener("resize", () => riveInstance.resizeDrawingSurfaceToCanvas());
  window
    .matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`)
    .addEventListener("change", () => riveInstance.resizeDrawingSurfaceToCanvas());
}
"""

CANVAS_SIZING_JS = """
document.querySelectorAll('canvas').forEach(canvas => {
  if (!canvas.hasAttribute("data-auto-w")) canvas.style.width = canvas.width + "px";
  if (!canvas.hasAttribute("data-auto-h")) canvas.style.height = canvas.height + "px";
});
"""

def layout_option_js(ctx, scale=1.0):
    """`layout:` constructor option for Fit.Layout canvases (empty otherwise)."""
    if not is_layout(ctx):
        return ""
    return f'layout: new rive.Layout({{ fit: rive.Fit.Layout, layoutScaleFactor: {scale:.6g} }}),'

def resize_call_js(var_name, canvas_id, ctx, scale=1.0):
    if not is_layout(ctx):
        return f'{var_name}.resizeDrawingSurfaceToCanvas();'
    auto_w = "true" if ctx.get("auto_w") else "false"
    auto_h = "true" if ctx.get("auto_h") else "false"
    return (f'autoSizeLayoutCanvas({var_name}, document.getElementById("{canvas_id}"), '
            f'{auto_w}, {auto_h}, {scale:.6g});')

DEFAULT_STATE_MACHINE = "State Machine 1"
DEFAULT_ARTBOARD = "main"
SCALAR_KEYS = {"sm": "state_machine", "artboard": "artboard", "trigger": "trigger"}
INPUT_TYPE_PREFIXES = {"num", "bol", "v_num", "v_bol", "txt", "col", "img", "list", "enum", "font"}

def strip_quotes(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value

def load_csv_rows(csv_file_path):
    """Parse the flexible CSV format: src,size,preview,token1,token2,...
    Tokens are freeform `key:value` pairs, any order/count, omitted when unused.
    Recognized scalar keys: sm, artboard, trigger.
    `note` may repeat; every occurrence is kept in row["notes"].
    Recognized input-type prefixes: num, bol, v_num, v_bol, txt, col, img, list, enum, font.
    """
    with open(csv_file_path, newline='', encoding='utf-8') as csvfile:
        lines = csvfile.read().splitlines()

    if not lines:
        return []

    rows = []
    for raw_line in lines[1:]:
        if not raw_line.strip():
            continue

        values = next(csv.reader([raw_line]))
        row = {
            "src": values[0].strip() if len(values) > 0 else "",
            "size": values[1].strip() if len(values) > 1 else "",
            "preview": values[2].strip() if len(values) > 2 else "",
            "inputs": [],
            "notes": [],
        }
        if row["src"].lower().endswith(".riv"):
            row["src"] = row["src"][:-4]

        for raw_token in values[3:]:
            token = raw_token.strip()
            if not token:
                continue
            key, sep, rest = token.partition(":")
            if not sep:
                print(f"Warning: ignoring malformed token '{token}' for {row['src']}")
                continue
            if key == "note":
                note = strip_quotes(rest)
                if note:
                    row["notes"].append(note)
            elif key in SCALAR_KEYS:
                value = strip_quotes(rest)
                if key == "artboard" and value == "-":
                    # Explicitly omit the artboard (e.g. old .riv files with a single,
                    # arbitrarily-named artboard) - let Rive use the file's only/default artboard.
                    value = ""
                row[SCALAR_KEYS[key]] = value
            elif key in INPUT_TYPE_PREFIXES:
                row["inputs"].append(token)
            else:
                print(f"Warning: unknown key '{key}' in token '{token}' for {row['src']}")

        rows.append(row)

    return rows

def scale_dimensions(width, height):
    if not SCALE_TO_200PX:
        return width, height
    try:
        width, height = int(width), int(height)
        if width == 200:
            return width, height
        scale = 200 / width
        return 200, int(round(height * scale))
    except (ValueError, TypeError):
        return width, height

@lru_cache(maxsize=128)
def get_display_name(src):
    name = os.path.splitext(src)[0]
    name = re.sub(r'_v\d+[a-zA-Z0-9]*', '', name)
    return name.replace('_', ' ')

def make_file_size_html(row):
    riv_path = os.path.join(script_dir, "riv", f'{row["src"]}.riv')
    size_kb = (os.path.getsize(riv_path) + 512) // 1024
    return f'<span class="riv-file-size">&nbsp&nbsp;{size_kb} KB</span>'

def sanitize_for_filename(value):
    value = (value or "").strip()
    value = re.sub(r'[^A-Za-z0-9_-]+', '_', value)
    return value.strip('_') or "artboard"

def assign_page_stems(rows):
    """Compute a unique detail-page filename stem for every row.
    Multiple rows can share the same .riv src (e.g. different artboards in one
    file) - each still needs its own detail page, otherwise later rows
    overwrite the page generated by earlier ones.
    """
    src_counts = {}
    for row in rows:
        src_counts[row["src"]] = src_counts.get(row["src"], 0) + 1

    seen_stems = set()
    for row in rows:
        stem = row["src"]
        if src_counts[row["src"]] > 1:
            suffix = sanitize_for_filename(row.get("artboard") or row.get("trigger") or "default")
            base_stem = f'{row["src"]}--{suffix}'
            stem = base_stem
            n = 2
            while stem in seen_stems:
                stem = f'{base_stem}-{n}'
                n += 1
        row["page_stem"] = stem
        seen_stems.add(stem)

def make_main_link(row, is_root=True):
    page_name = row.get("page_stem", row["src"]) + ".html"
    display_name = get_display_name(row["src"])
    prefix = "pages/" if is_root else ""
    return f'<a href="{prefix}{page_name}" style="color: #888888;">{display_name}</a>'

def parse_input_type_name(input_value):
    """Parse input value and return type and name"""
    if not input_value:
        return None, None
    input_value = input_value.strip()
    if ":" in input_value:
        t, n = input_value.split(":", 1)
        return t.strip(), n.strip()
    return "num", input_value.strip()

def parse_input_spec(input_value):
    """Return (type, name_without_default, default_value_or_None). Supports name(default)."""
    t, name = parse_input_type_name(input_value)
    default = None
    if name and name.endswith(")") and "(" in name:
        m = re.match(r'^(.*)\(([^()]*)\)\s*$', name)
        if m:
            name = m.group(1).strip()
            default = m.group(2).strip()
            # Strip wrapping quotes if present (e.g. from name("value")); enum keeps its quoted option list
            if t != "enum" and len(default) >= 2 and ((default.startswith('"') and default.endswith('"')) or (default.startswith("'") and default.endswith("'"))):
                default = default[1:-1]
    return t, name, default

def parse_font_spec(input_value):
    """Return (asset_name, filename) for font:"File.otf" tokens.
    The Rive font asset name is the file name without extension; font:AssetName(File.otf)
    can be used when the file name differs from the asset name.
    """
    _t, name, default = parse_input_spec(input_value)
    name = strip_quotes(name or "")
    if default:
        return os.path.splitext(name)[0], default
    return os.path.splitext(name)[0], name

def parse_enum_spec(value):
    """Return (default, options) for enum defaults like EN:EN|ES|RU or just EN|ES|RU (pipe-separated, CSV-safe)."""
    value = value or ""
    default_part, sep, options_part = value.partition(":")
    if not sep:
        default_part, options_part = "", value
    options = [strip_quotes(o) for o in options_part.split("|") if o.strip()]
    default = strip_quotes(default_part)
    if default and default not in options:
        options.insert(0, default)
    if not default and options:
        default = options[0]
    return default, options

def parse_number_range(value):
    """Return (current, minimum, maximum, step) for current:min-max syntax."""
    if not value:
        return None
    match = re.fullmatch(r'\s*(-?(?:\d+(?:\.\d*)?|\.\d+))\s*:\s*(-?(?:\d+(?:\.\d*)?|\.\d+))\s*-\s*(-?(?:\d+(?:\.\d*)?|\.\d+))\s*', value)
    if not match:
        return None

    current, minimum, maximum = match.groups()
    precision = max(
        len(part.partition(".")[2]) if "." in part else 0
        for part in (current, minimum, maximum)
    )
    step = "1" if precision == 0 else f"{10 ** -precision:.{precision}f}"
    return current, minimum, maximum, step

def make_range_ticks(minimum, maximum, step):
    intervals = int((Decimal(maximum) - Decimal(minimum)) / Decimal(step))
    if intervals <= 1:
        return ""
    stride = max(1, (intervals - 1 + 49) // 50)
    return "".join(
        f'<span style="left:{index * 100 / intervals:.8f}%;"></span>'
        for index in range(stride, intervals, stride)
    )

# NEW helpers for list input
def camel_to_words(name: str):
    return re.sub(r'(?<!^)(?=[A-Z])', '', name).strip()

def parse_list_inner(spec: str):
    """
    Parse inner spec like num:BarHeight (only num supported now).
    Returns (inner_type, inner_name)
    """
    spec = spec.strip()
    if ":" in spec:
        t, n = spec.split(":", 1)
        return t.strip(), n.strip()
    return "num", spec

def random_color_hex():
    # Returns a random color in #RRGGBB format
    return "#{:06x}".format(random.randint(0, 0xFFFFFF))

def parse_input_field(input_value, input_idx, button_id, control_width=None, detail=False):
    input_type, input_name, default_val = parse_input_spec(input_value)
    # Handle list:Name[innerSpec] -> no direct HTML, skip rendering
    if input_type == "list":
        return ""
    if not input_type:
        return ""
    input_id = f"{button_id}_input{input_idx}"
    # Each label+input in a row
    if input_type == "num":
        value_attr = default_val if default_val is not None else "80"
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="number" id="{input_id}" value="{value_attr}" style="width:50px;" />
        </div>
        '''
    elif input_type == "v_num":  # NEW: view model number variable
        value_attr = default_val if default_val is not None else "0"
        number_range = parse_number_range(default_val)
        if number_range:
            current, minimum, maximum, step = number_range
            minimum_value = float(minimum)
            maximum_value = float(maximum)
            progress = 0 if maximum_value == minimum_value else (float(current) - minimum_value) / (maximum_value - minimum_value) * 100
            slider_width = "100%" if detail else f"{control_width + 2 if control_width is not None else 180}px"
            ticks = make_range_ticks(minimum, maximum, step)
            return f'''
        <div class="range-control" style="width:{slider_width};--slider-progress:{progress:.4f}%;">
            <output for="{input_id}">{current}</output>
            <span class="range-ticks" aria-hidden="true">{ticks}</span>
            <input type="range" id="{input_id}" value="{current}" min="{minimum}" max="{maximum}" step="{step}" aria-label="{input_name}" />
            <span class="range-bound range-min">{minimum}</span>
            <span class="range-bound range-max">{maximum}</span>
        </div>
        '''
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="number" id="{input_id}" value="{value_attr}" style="width:60px;" />
        </div>
        '''
    elif input_type == "txt":
        value_attr = default_val if default_val is not None else ""
        value_attr = value_attr.replace('"', '&quot;')
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="text" id="{input_id}" value="{value_attr}" style="width:90px;" />
        </div>
        '''
    elif input_type == "bol":
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="checkbox" id="{input_id}" />
        </div>
        '''
    elif input_type == "col":
        default_color = random_color_hex()
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="color" id="{input_id}" value="{default_color}" />
        </div>
        '''
    elif input_type == "v_bol":  # NEW: view model boolean variable
        # Support defaults via name(true)/name(false)
        checked = False
        if default_val is not None:
            if str(default_val).strip().lower() in ("true", "1", "yes", "y", "on", "checked"):
                checked = True
        checked_attr = " checked" if checked else ""
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="checkbox" id="{input_id}"{checked_attr} />
        </div>
        '''
    elif input_type == "enum":  # ViewModel enum variable rendered as a dropdown
        enum_default, enum_options = parse_enum_spec(default_val)
        options_html = "".join(
            f'<option value="{html_escape(o)}"{" selected" if o == enum_default else ""}>{html_escape(o)}</option>'
            for o in enum_options
        )
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <select id="{input_id}">{options_html}</select>
        </div>
        '''
    elif input_type == "img":  # NEW: ViewModel image variable (expects filename in img folder)
        value_attr = default_val if default_val is not None else ""
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="text" id="{input_id}" placeholder="filename.ext" value="{value_attr}" style="width:100px;" />
        </div>
        '''
    elif input_type == "font":  # Referenced font asset loaded from the fonts folder by file name
        asset_name, font_file = parse_font_spec(input_value)
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{html_escape(asset_name)}:</label>
            <input type="text" id="{input_id}" placeholder="font.otf" value="{html_escape(font_file)}" style="width:90px;" />
        </div>
        '''
    return ""

def make_input_js(input_type, input_name, input_id, obj_var, field_var):
    js_configs = {
        "num": f'''
    // Initial assignment from default value (if any)
    let initVal = parseFloat({field_var}.value);
    if (!isNaN(initVal)) {obj_var}.value = initVal;
    {field_var}.addEventListener("input", () => {{
      let val = parseFloat({field_var}.value);
      if (!isNaN(val)) {obj_var}.value = val;
    }});''',
        "bol": f'''
    {obj_var}.value = {field_var}.checked;
    {field_var}.addEventListener("change", () => {{
      {obj_var}.value = {field_var}.checked;
    }});''',
        "txt": f'''
    {obj_var}.value = {field_var}.value;
    {field_var}.addEventListener("input", () => {{
      {obj_var}.value = {field_var}.value;
    }});''',
        "col": f'''
    let hex = {field_var}.value.replace("#", "");
    {obj_var}.value = parseInt("FF" + hex.toUpperCase(), 16);
    {field_var}.addEventListener("input", () => {{
      let hex = {field_var}.value.replace("#", "");
      let argb = parseInt("FF" + hex.toUpperCase(), 16);
      {obj_var}.value = argb;
    }});'''
    }
    return js_configs.get(input_type, "")

def collect_input_fields(row, button_id, control_width):
    """Collect all input fields for a row"""
    inputs_html = []
    for i, input_value in enumerate(row.get("inputs", [])):
        inputs_html.append(parse_input_field(input_value, i, button_id, control_width))
    return "".join(inputs_html)

def make_main_canvas(idx, row, is_root=True):
    canvas_id = f"canvas{idx}"
    button_id = f"btn{idx}"
    width, height, _scale = catalog_canvas_size(row)
    canvas_ctx = {**row, "width": width, "height": height}

    # Build button HTML
    button_html = ""
    if row.get("trigger"):
        button_html = f'<button id="{button_id}" class="rive-btn" style="margin-left:auto;">Trigger</button>'

    # Collect input fields (below the row)
    inputs_html = collect_input_fields(row, button_id, control_width_for(canvas_ctx))
    if inputs_html:
        inputs_html = f'''
        <div class="controls-column" style="display:flex;flex-direction:column;align-items:flex-end;margin-top:8px;">
            {inputs_html}
        </div>
        '''
    else:
        inputs_html = ""

    desc = f'''
      <div style="display: flex; flex-direction: column; align-items: stretch;">
        <div style="display: flex; align-items: center; width: 100%;">
          <div style="white-space: nowrap;">{make_main_link(row, is_root)}{make_file_size_html(row)}</div>
          {button_html}
        </div>
        {inputs_html}
      </div>
    '''
    return f'''
      <div class="animation-container">
        <canvas {canvas_attrs(canvas_ctx, canvas_id)}></canvas>
        <div class="description">
          {desc}
        </div>
      </div>
    '''

def generate_rive_config(idx, row):
    """Generate Rive configuration for a canvas"""
    canvas_id = f"canvas{idx}"
    src = f"riv/{row['src']}"
    state_machine = row.get("state_machine", "")
    artboard = row.get("artboard", "")
    
    artboard_line = f'artboard: "{artboard}",' if artboard else ""
    state_machine_line = f' stateMachines: "{state_machine}",' if state_machine else ""
    
    return f'''
const r{idx} = new rive.Rive({{
  src: "{src}",
  canvas: document.getElementById("{canvas_id}"),
  autoplay: true, autoBind: true,{artboard_line}{state_machine_line}
  onLoad: () => {{
    r{idx}.resizeDrawingSurfaceToCanvas();
  }},
}});
'''

def generate_text_input_js(row, prefix, rive_var, include_vmi=False):
    """Generate JS for ViewModel-based inputs (txt, col, v_num, v_bol, img, list)."""
    js_parts = []
    has_vmi_inputs = False
    for i, input_value in enumerate(row.get("inputs", [])):
        input_type, name_spec, _default = parse_input_spec(input_value)
        input_name = name_spec  # ensure name available for non-list types
        list_match = None
        if input_type == "list" and name_spec:
            list_match = re.match(r'^([^\[]+)\[(.+)\]$', name_spec)
        input_id = f"{prefix}_input{i}"
        field_var = f"inputField{prefix.title()}_{i}"
        if input_type in ("txt", "col", "v_num", "v_bol", "img", "enum"):
            has_vmi_inputs = True
            if input_type == "txt":
                js_parts.append(f"    let {field_var} = document.getElementById(\"{input_id}\");\n")
                js_parts.append(f"""    if ({field_var} && vmi) {{
      vmi.string("{input_name}").value = {field_var}.value;
      {field_var}.addEventListener("input", () => {{
        vmi.string("{input_name}").value = {field_var}.value;
      }});
    }}
""")
            elif input_type == "col":
                js_parts.append(f"    let {field_var} = document.getElementById(\"{input_id}\");\n")
                js_parts.append(f"""    if ({field_var} && vmi) {{
      // Set initial color value
      let hex = {field_var}.value.replace("#", "");
      let argb = parseInt("FF" + hex.toUpperCase(), 16);
      vmi.color("{input_name}").value = argb;
      {field_var}.addEventListener("input", () => {{
        let hex = {field_var}.value.replace("#", "");
        let argb = parseInt("FF" + hex.toUpperCase(), 16);
        vmi.color("{input_name}").value = argb;
      }});
    }}
""")
            elif input_type == "v_num":
                js_parts.append(f"    let {field_var} = document.getElementById(\"{input_id}\");\n")
                js_parts.append(f"""    if ({field_var} && vmi) {{
      // Update numeric ViewModel variable
      {field_var}.addEventListener("input", () => {{
        let val = parseFloat({field_var}.value);
                if (!isNaN(val)) vmi.number("{input_name}").value = val;
                const rangeControl = {field_var}.closest(".range-control");
                if (rangeControl) {{
                    rangeControl.querySelector("output").value = {field_var}.value;
                    const minimum = Number({field_var}.min);
                    const maximum = Number({field_var}.max);
                    const progress = maximum === minimum ? 0 : ({field_var}.value - minimum) / (maximum - minimum) * 100;
                    rangeControl.style.setProperty("--slider-progress", `${{progress}}%`);
                }}
      }});
      // Set initial value if present
      let initVal = parseFloat({field_var}.value);
      if (!isNaN(initVal)) vmi.number("{input_name}").value = initVal;
    }}
""")
            elif input_type == "v_bol":
                js_parts.append(f"    let {field_var} = document.getElementById(\"{input_id}\");\n")
                js_parts.append(f"""    if ({field_var} && vmi) {{
      // Update boolean ViewModel variable
      {field_var}.addEventListener("change", () => {{
        vmi.boolean("{input_name}").value = {field_var}.checked;
      }});
      // Set initial value
      vmi.boolean("{input_name}").value = {field_var}.checked;
    }}
""")
            elif input_type == "enum":
                js_parts.append(f"    let {field_var} = document.getElementById(\"{input_id}\");\n")
                js_parts.append(f"""    if ({field_var} && vmi) {{
      const enumProp_{prefix}_{i} = vmi.enum("{input_name}");
      if (enumProp_{prefix}_{i}) {{
        enumProp_{prefix}_{i}.value = {field_var}.value;
        {field_var}.addEventListener("change", () => {{
          enumProp_{prefix}_{i}.value = {field_var}.value;
        }});
      }} else {{
        console.warn("Enum not found in view model: {input_name}");
      }}
    }}
""")
            elif input_type == "img":
                js_parts.append(f"    let {field_var} = document.getElementById(\"{input_id}\");\n")
                js_parts.append(f"""    if ({field_var} && vmi) {{
      const imgProp_{prefix}_{i} = vmi.image("{input_name}");
      let lastImg_{prefix}_{i} = null;
      const imgBase_{prefix}_{i} = location.pathname.includes('/pages/') ? '../img/' : 'img/';

      async function loadImg_{prefix}_{i}(filename) {{
        const name = (filename || "").trim();
        if (!name) return;
        try {{
          const res = await fetch(imgBase_{prefix}_{i} + name);
          const bytes = new Uint8Array(await res.arrayBuffer());
          if (!rive.decodeImage) {{
            console.warn("rive.decodeImage is not available.");
            return;
          }}
          const decoded = await rive.decodeImage(bytes);
          if (lastImg_{prefix}_{i}) lastImg_{prefix}_{i}.unref();
          imgProp_{prefix}_{i}.value = decoded;
          lastImg_{prefix}_{i} = decoded;
        }} catch (e) {{
          console.error("Failed to load image:", name, e);
        }}
      }}

      {field_var}.addEventListener("change", () => {{
        loadImg_{prefix}_{i}({field_var}.value);
      }});

      // Initial load if a default or preset value exists
      if ({field_var}.value && {field_var}.value.trim() !== "") {{
        loadImg_{prefix}_{i}({field_var}.value);
      }}
    }}
""")
        elif input_type == "list" and list_match:
            has_vmi_inputs = True
            list_name_raw = list_match.group(1).strip()
            inner_spec = list_match.group(2).strip()
            inner_t, inner_name = parse_list_inner(inner_spec)
            list_name_vmi = camel_to_words(list_name_raw)
            if inner_t == "num":
                js_parts.append(f"""    if (vmi) {{
      const listVar_{i} = vmi.list("{list_name_vmi}");
      if (listVar_{i}) {{
        for (let idx = 0; idx < listVar_{i}.length; idx++) {{
          const inst = listVar_{i}.instanceAt(idx);
          if (inst) {{
            // Demo assignment; replace with real data source as needed
            //const randomVal = Math.random() * 100;
            //inst.number("{inner_name}").value = randomVal;
          }}
        }}
      }}
    }}
""")
    if has_vmi_inputs or include_vmi:
        js_parts.insert(0, f"    const vmi = {rive_var}.viewModelInstance;\n")
    return "".join(js_parts)

def generate_image_asset_loader(row, is_root):
    """Generate the loader required for externally packaged Rive image assets."""
    for input_value in row.get("inputs", []):
        input_type, _input_name, default_value = parse_input_spec(input_value)
        if input_type == "img" and default_value:
            image_path = ("img/" if is_root else "../img/") + default_value
            return f'''    assetLoader: (asset) => {{
      if (!asset.isImage) return false;
      fetch({json.dumps(image_path)})
        .then(response => response.arrayBuffer())
        .then(bytes => rive.decodeImage(new Uint8Array(bytes)))
        .then(image => {{
          asset.setRenderImage(image);
          image.unref();
        }})
        .catch(error => console.error("Failed to load Rive image asset:", error));
      return true;
    }},
'''
    return ""

def generate_asset_loader(row, is_root, prefix):
    """Generate the assetLoader option: referenced fonts (file name taken from the page's text
    field, so editing it swaps the font live) plus the existing image asset loader."""
    font_fields = {}
    for i, input_value in enumerate(row.get("inputs", [])):
        if parse_input_spec(input_value)[0] == "font":
            asset_name, _font_file = parse_font_spec(input_value)
            font_fields[asset_name] = f"{prefix}_input{i}"
    if not font_fields:
        return generate_image_asset_loader(row, is_root)

    fonts_dir = "fonts/" if is_root else "../fonts/"
    image_loader = generate_image_asset_loader(row, is_root)
    image_branch = ""
    if image_loader:
        # Reuse the image loader's body, nested after the font branch.
        body = image_loader.split("assetLoader: (asset) => {", 1)[1].rsplit("},", 1)[0]
        image_branch = body
    else:
        image_branch = "\n      return false;\n    "
    return f'''    assetLoader: (asset) => {{
      const fontFields = {json.dumps(font_fields)};
      if (asset.isFont && fontFields[asset.name]) {{
        const field = document.getElementById(fontFields[asset.name]);
        const loadFont = (file) => {{
          const name = (file || "").trim();
          if (!name) return;
          fetch({json.dumps(fonts_dir)} + name)
            .then(response => {{
              if (!response.ok) throw new Error("HTTP " + response.status);
              return response.arrayBuffer();
            }})
            .then(bytes => rive.decodeFont(new Uint8Array(bytes)))
            .then(font => {{
              asset.setFont(font);
              font.unref();
            }})
            .catch(error => console.error("Failed to load Rive font asset:", name, error));
        }};
        loadFont(field && field.value);
        if (field) field.addEventListener("change", () => loadFont(field.value));
        return true;
      }}{image_branch}}},
'''

def generate_rive_js_block(var_name, canvas_id, src, artboard, state_machine, trigger, input_prefix, row, is_root=True, layout_scale=1.0):
    artboard_line = f'artboard: "{artboard}",' if artboard else ""
    state_machine_line = f' stateMachines: "{state_machine}",' if state_machine else ""
    asset_loader = generate_asset_loader(row, is_root, input_prefix)
    trigger_js = ""
    js = [f'''
const {var_name} = new rive.Rive({{
    src: "{src}",
    canvas: document.getElementById("{canvas_id}"),
    autoplay: true, autoBind: true,{artboard_line}{state_machine_line}
    {layout_option_js(row, layout_scale)}
{asset_loader}
    onLoad: () => {{
        {resize_call_js(var_name, canvas_id, row, layout_scale)}
''']

    js.append(generate_text_input_js(row, input_prefix, var_name, include_vmi=bool(trigger)))

    if state_machine:
        if trigger:
            trigger_js = f'''document.getElementById("{input_prefix}").addEventListener("click", () => {{
    const currentVmi = {var_name}.viewModelInstance;
    if (currentVmi) {{
        const vmTrigger = currentVmi.trigger("{trigger}");
        if (vmTrigger) {{
            vmTrigger.trigger();
            return;
        }}
    }}
    const inputs = {var_name}.stateMachineInputs("{state_machine}");
    const smTrigger = inputs && inputs.find(input => input.name === "{trigger}");
    if (smTrigger) {{
        smTrigger.fire();
    }} else {{
        console.warn("Trigger not found (view model or state machine): {trigger}");
    }}
}});
'''

        if any(parse_input_spec(value)[0] in ("num", "bol") for value in row.get("inputs", [])):
            js.append(f'    const inputs = {var_name}.stateMachineInputs("{state_machine}");\n')

        for i, input_value in enumerate(row.get("inputs", [])):
            input_type, input_name, _default = parse_input_spec(input_value)
            if input_type in ("txt", "col", "v_num", "v_bol", "list", "enum", "font"):
                continue
            input_id = f"{input_prefix}_input{i}"
            field_var = f'inputField_{input_prefix}_{i}'
            obj_var = f'inputObj_{input_prefix}_{i}'
            js.append(f'    let {field_var} = document.getElementById("{input_id}");\n')
            js.append(f'    let {obj_var} = inputs.find(input => input.name === "{input_name}");\n')
            if input_type == "num":
                js.append(f'''    if ({field_var} && {obj_var}) {{
        let val = parseFloat({field_var}.value);
        if (!isNaN(val)) {obj_var}.value = val;
        {field_var}.addEventListener("input", () => {{
            let val = parseFloat({field_var}.value);
            if (!isNaN(val)) {obj_var}.value = val;
        }});
    }}
''')
            elif input_type == "bol":
                js.append(f'''    if ({field_var} && {obj_var}) {{
        {obj_var}.value = {field_var}.checked;
        {field_var}.addEventListener("change", () => {{
            {obj_var}.value = {field_var}.checked;
        }});
    }}
''')
    js.append('  },\n});\n')
    js.append(trigger_js)
    return "".join(js)

def make_script(rows, is_root=True):
    script_parts = ["<script>\n"]
    if any(is_layout(row) for row in rows):
        script_parts.append(AUTO_SIZE_LAYOUT_JS)
    riv_prefix = "" if is_root else "../"
    for idx, row in enumerate(rows):
        canvas_id = f"canvas{idx}"
        button_id = f"btn{idx}"
        src = f"{riv_prefix}riv/{row['src']}.riv"
        artboard = row.get("artboard", "")
        state_machine = row.get("state_machine", "")
        trigger = row.get("trigger", "")

        # Use unified function
        script_parts.append(
            generate_rive_js_block(
                var_name=f"r{idx}",
                canvas_id=canvas_id,
                src=src,
                artboard=artboard,
                state_machine=state_machine,
                trigger=trigger,
                input_prefix=button_id,
                row=row,
                is_root=is_root,
                layout_scale=catalog_canvas_size(row)[2]
            )
        )

    # Canvas sizing and auto-trigger
    script_parts.append(CANVAS_SIZING_JS + '''
// Fire all triggers 3 seconds after page load
setTimeout(() => {
  document.querySelectorAll('.rive-btn[id^="btn"]').forEach(btn => {
    btn.click();
  });
}, 3000);
</script>
''')
    return "".join(script_parts)

def make_description_html(row):
    # Compose size from width and height
    size_str = size_label(row)
    parts = [
        f'Size: {size_str}<br>',
        f'State Machine: {row["state_machine"]}<br>'
    ]

    optional_fields = [
        ("artboard", "Artboard"),
        ("trigger", "Trigger"),
    ]

    for field, label in optional_fields:
        if row.get(field):
            parts.append(f'{label}: {row[field]}<br>')

    for note in row.get("notes", []):
        parts.append(f'Note: {note}<br>')

    # Add all non-empty inputs
    for input_value in row.get("inputs", []):
        parts.append(f'Input: {input_value}<br>')

    return "".join(parts)

def make_animation_inputs(row, prefix, control_width):
    """Generate animation input HTML"""
    html_parts = []
    for i, input_value in enumerate(row.get("inputs", [])):
        html_parts.append(parse_input_field(input_value, i, prefix, control_width, detail=True))
    return "".join(html_parts)

def check_preview_exists(row):
    """Check if preview file exists"""
    src_base = os.path.splitext(row["src"])[0]
    preview_file = f'{src_base}_preview.riv'
    preview_path = os.path.join(script_dir, "riv", preview_file)
    return f'../riv/{preview_file}' if os.path.exists(preview_path) else None

def make_animation_page(row):
    page_name = row.get("page_stem", row["src"]) + ".html"
    main_rive = f'../riv/{row["src"]}.riv'
    
    # Determine preview configuration
    preview_ctx = None
    if row.get("preview") and row["preview"].strip():
        # Internal preview
        preview_ctx = {
            "src": main_rive,
            **parse_size_spec(row["preview"]),
            "artboard": "preview"
        }
    else:
        # External preview check
        preview_path = check_preview_exists(row)
        if preview_path:
            preview_ctx = {
                "src": preview_path,
                "width": row["width"],
                "height": row["height"],
                "auto_w": row.get("auto_w", False),
                "auto_h": row.get("auto_h", False),
                "artboard": row.get("artboard", "")
            }

    html_parts = [get_html_head(is_root=False)]
    # Inject BG button (is_root=False because this is in pages/)
    html_parts.append(get_bg_button_html(is_root=False))
    
    # Generate main content based on preview existence
    if preview_ctx:
        html_parts.append(generate_dual_animation_html(row, preview_ctx))
    else:
        html_parts.append(generate_single_animation_html(row))
    
    # Generate JavaScript
    html_parts.append(generate_animation_js(row, main_rive, preview_ctx))
    html_parts.append(html_foot)
    
    # Write file
    with open(os.path.join(pages_dir, page_name), "w", encoding="utf-8") as f:
        f.write("".join(html_parts))

def generate_detail_animation_html(row, canvas_ctx, canvas_type):
    prefix = f"btn_{canvas_type}"
    if canvas_type == "main":
        title = f'<span style="white-space: nowrap;"><a href="../riv/{row["src"]}.riv" target="_blank" style="color: white;">{get_display_name(row["src"])}</a>{make_file_size_html(row)}</span>'
        metadata = make_description_html(row)
    else:
        title = "Preview:"
        metadata = ""
    button = f'<button id="{prefix}" class="rive-btn" style="margin-left:auto;">Trigger</button>' if row.get("trigger") else ""
    inputs = make_animation_inputs(row, prefix, control_width_for(canvas_ctx))
    controls = f'<div class="controls-column" style="margin-top:8px;">{inputs}</div>' if inputs else ""
    return f'''
      <div class="animation-container detail-animation">
        <canvas {canvas_attrs(canvas_ctx, f"{canvas_type}_canvas")}></canvas>
        <div class="description">
          <div style="display:flex;align-items:center;width:100%;">
            <div>{title}</div>
            {button}
          </div>
          {metadata}
          {controls}
        </div>
      </div>
'''

def generate_single_animation_html(row):
    """Generate HTML for single animation layout"""
    return generate_detail_animation_html(row, row, "main")

def generate_dual_animation_html(row, preview_ctx):
    """Generate HTML for dual animation layout"""
    return f'''
    <div class="animation-row" style="display: flex; gap: 32px; align-items: flex-start;">
      {generate_detail_animation_html(row, row, "main")}
      {generate_detail_animation_html(row, preview_ctx, "preview")}
    </div>
'''

def generate_animation_js(row, main_rive, preview_ctx):
    """Generate JavaScript for animation page"""
    js_parts = ['<script>\n']
    if is_layout(row) or (preview_ctx and is_layout(preview_ctx)):
        js_parts.append(AUTO_SIZE_LAYOUT_JS)

    # Main animation
    asset_loader = generate_asset_loader(row, is_root=False, prefix="btn_main")
    js_parts.append(f'''
const mainRive = new rive.Rive({{
  src: "{main_rive}",
  canvas: document.getElementById("main_canvas"),
  autoplay: true,autoBind: true,{f' artboard: "{row["artboard"]}",' if row.get("artboard") else ""}{f' stateMachines: "{row["state_machine"]}",' if row.get("state_machine") else ""}
  {layout_option_js(row)}
{asset_loader}
  onLoad: () => {{
    {resize_call_js("mainRive", "main_canvas", row)}
''')
    
    # Handle text inputs in onLoad for main
    js_parts.append(generate_text_input_js(row, "btn_main", "mainRive"))
    js_parts.append('  },\n});\n')
    
    # Main animation controls
    js_parts.append(generate_animation_controls_js(row, "main", "mainRive"))
    
    # Preview animation if exists
    if preview_ctx:
        js_parts.append(generate_preview_animation_js(row, preview_ctx))
    
    js_parts.append(CANVAS_SIZING_JS + "</script>\n")
    
    return "".join(js_parts)

def generate_animation_controls_js(row, canvas_type, rive_var):
    """Generate animation control JavaScript"""
    js_parts = []

    # Trigger handling: try ViewModel trigger first, fall back to state machine trigger
    if row.get("trigger"):
        js_parts.append(f'''
document.getElementById("btn_{canvas_type}").addEventListener("click", () => {{
    const vmi = {rive_var}.viewModelInstance;
    if (vmi) {{
        const vmTrigger = vmi.trigger("{row["trigger"]}");
        if (vmTrigger) {{
            vmTrigger.trigger();
            return;
        }}
    }}
    const inputs = {rive_var}.stateMachineInputs("{row["state_machine"]}");
    const smTrigger = inputs && inputs.find(input => input.name === "{row["trigger"]}");
    if (smTrigger) {{
        smTrigger.fire();
    }} else {{
        console.warn("Trigger not found (view model or state machine): {row["trigger"]}");
    }}
}} );
''')

    # Input handling for num/bool
    for i, input_value in enumerate(row.get("inputs", [])):
        input_type, input_name, _default = parse_input_spec(input_value)
        if input_type in ["num", "bol"]:
            input_id = f"btn_{canvas_type}_input{i}"
            js_parts.append(f'''
let inputField{canvas_type.title()}_{i} = document.getElementById("{input_id}");
{rive_var}.on("load", () => {{
  const inputs = {rive_var}.stateMachineInputs("{row["state_machine"]}");
  let inputObj{canvas_type.title()}_{i} = inputs.find(input => input.name === "{input_name}");
  if (inputField{canvas_type.title()}_{i} && inputObj{canvas_type.title()}_{i}) {{
{make_input_js(input_type, input_name, input_id, f"inputObj{canvas_type.title()}_{i}", f"inputField{canvas_type.title()}_{i}")}
  }}
}});
''')
        # v_num, txt, col, img, list skipped (handled via ViewModel)
    return "".join(js_parts)

def generate_preview_animation_js(row, preview_ctx):
    """Generate preview animation JavaScript"""
    artboard_val = preview_ctx.get("artboard", "")
    artboard_prop = f' artboard: "{artboard_val}",' if artboard_val else ""
    asset_loader = generate_asset_loader(row, is_root=False, prefix="btn_preview")

    js_parts = [f'''
const previewRive = new rive.Rive({{
  src: "{preview_ctx["src"]}",
  canvas: document.getElementById("preview_canvas"),
  autoplay: true, autoBind: true,{artboard_prop}{f' stateMachines: "{row["state_machine"]}",' if row.get("state_machine") else ""}
  {layout_option_js(preview_ctx)}
{asset_loader}
  onLoad: () => {{
    {resize_call_js("previewRive", "preview_canvas", preview_ctx)}
''']
    
    js_parts.append(generate_text_input_js(row, "btn_preview", "previewRive"))
    js_parts.append('  },\n});\n')
    js_parts.append(generate_animation_controls_js(row, "preview", "previewRive"))
    
    return "".join(js_parts)

def make_pagination_buttons(current_page, total_pages):
    buttons = []
    for i in range(total_pages):
        label = str(i + 1)
        
        if i == current_page:
            buttons.append(f'<button class="rive-btn" style="background:#e0e0e0;color:#333;">{label}</button>')
        else:
            if current_page == 0:
                # From root index.html
                target = "index.html" if i == 0 else f"pages/page{i}.html"
            else:
                # From inside pages/
                target = "../index.html" if i == 0 else f"page{i}.html"
            
            buttons.append(f'<a href="{target}"><button class="rive-btn">{label}</button></a>')
    
    return '<div style="margin: 24px 0; text-align:center;">' + " ".join(buttons) + "</div>"

def write_main_page(page_rows, page_idx, total_pages):
    filename = output_html if page_idx == 0 else os.path.join(pages_dir, f"page{page_idx}.html")
    is_root = (page_idx == 0)
    
    with open(filename, "w", encoding="utf-8") as f:
        content_parts = [
            get_html_head(is_root=is_root),
            get_bg_button_html(is_root=is_root),  # Inject BG button
            "".join(make_main_canvas(idx, row, is_root) for idx, row in enumerate(page_rows)),
            "</div>\n",
            make_script(page_rows, is_root),
            make_pagination_buttons(page_idx, total_pages),
            html_foot
        ]
        f.write("".join(content_parts))

def copy_recent_riv_files(src_dir, dst_dir, age_seconds=300):
    """Recursively copy .riv files less than `age_seconds` old from src_dir to dst_dir."""
    if not src_dir or not os.path.isdir(src_dir):
        print(f"Skip copying .riv files: source directory not found: {src_dir}")
        return
    os.makedirs(dst_dir, exist_ok=True)
    now = time.time()
    for root, _, files in os.walk(src_dir):
        for file in files:
            if file.lower().endswith('.riv'):
                src_path = os.path.join(root, file)
                if now - os.path.getmtime(src_path) < age_seconds:
                    dst_path = os.path.join(dst_dir, file)
                    try:
                        shutil.copy2(src_path, dst_path)
                        print(f"Copied {src_path} to {dst_path}")
                    except Exception as e:
                        print(f"Failed to copy {src_path} to {dst_path}: {e}")

# NEW: Resolve cross-platform source directory (env var first, then common defaults)
def resolve_src_dir():
    env_path = os.environ.get("RIV_SRC_DIR")
    if env_path and os.path.isdir(env_path):
        return env_path
    candidates = [
        r"c:\Dropbox\_Job\_Welltory",  # Windows default
        "/Users/yuri/Library/CloudStorage/Dropbox/_Job/_Welltory",  # macOS Dropbox CloudStorage
        "/Users/yuri/Dropbox/_Job/_Welltory",  # macOS standard Dropbox
    ]
    for p in candidates:
        if os.path.isdir(p):
            return p
    return None

# Main execution
def main():
    rows = load_csv_rows(csv_path)[::-1]

    # Apply defaults
    for row in rows:
        if not row.get("state_machine") or row["state_machine"].strip() == "":
            row["state_machine"] = DEFAULT_STATE_MACHINE
        # Only apply the default artboard when it was never specified in the CSV.
        # If the row explicitly set artboard:- , "artboard" is present but empty -
        # leave it empty so no artboard is passed to Rive.
        if "artboard" not in row:
            row["artboard"] = DEFAULT_ARTBOARD

        # Parse size column into width/height for backward compatibility
        row.update(parse_size_spec(row.get("size")))

    # Give each row a unique detail-page filename (handles multiple artboards
    # sharing one .riv src).
    assign_page_stems(rows)

    # Generate per-animation pages
    for row in rows:
        make_animation_page(row)

    # Generate paginated main pages
    total_pages = (len(rows) + ANIMATIONS_PER_PAGE - 1) // ANIMATIONS_PER_PAGE
    for page_idx in range(total_pages):
        start = page_idx * ANIMATIONS_PER_PAGE
        end = start + ANIMATIONS_PER_PAGE
        page_rows = rows[start:end]
        write_main_page(page_rows, page_idx, total_pages)

    print(f"Generated {output_html}, {total_pages-1} extra pages, and {len(rows)} animation pages in 'pages/'")

if __name__ == "__main__":
    # Ensure destination riv folder exists
    dest_riv_dir = os.path.join(script_dir, "riv")
    os.makedirs(dest_riv_dir, exist_ok=True)

    # Copy recent .riv files before generating HTML (cross-platform)
    src_dir = resolve_src_dir()
    age = int(os.environ.get("RIV_COPY_AGE_SECONDS", "300"))
    if not src_dir:
        print("No .riv source directory found. Set RIV_SRC_DIR to your .riv folder to enable auto-copy.")
    copy_recent_riv_files(src_dir, dest_riv_dir, age_seconds=age)

    main()