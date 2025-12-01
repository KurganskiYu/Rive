import os
import csv
import re
from functools import lru_cache
import shutil
import time
import random

script_dir = os.path.dirname(os.path.abspath(__file__))
csv_path = os.path.join(script_dir, "videos.csv")
output_html = os.path.join(script_dir, "index.html")
head_html_path = os.path.join(script_dir, "head.html")
pages_dir = os.path.join(script_dir, "pages")
os.makedirs(pages_dir, exist_ok=True)

# Cache file reads
@lru_cache(maxsize=1)
def get_html_head():
    with open(head_html_path, "r", encoding="utf-8") as head_file:
        return head_file.read()

html_foot = """
    </div>
</body>
</html>
"""

SCALE_TO_200PX = True
ANIMATIONS_PER_PAGE = 8
INPUT_RANGE = range(1, 7)  # Constant for input iteration

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

def make_main_link(row):
    page_name = os.path.splitext(row["src"])[0] + ".html"
    display_name = get_display_name(row["src"])
    return f'<a href="pages/{page_name}" style="color: #464646;">{display_name}</a>'

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
    return t, name, default

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

def parse_input_field(input_value, input_idx, button_id):
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
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="number" id="{input_id}" value="{value_attr}" style="width:60px;" />
        </div>
        '''
    elif input_type == "txt":
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="text" id="{input_id}" style="width:90px;" />
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
    elif input_type == "img":  # NEW: ViewModel image variable (expects filename in img folder)
        value_attr = default_val if default_val is not None else ""
        return f'''
        <div style="display:flex;align-items:center;gap:4px;">
            <label for="{input_id}">{input_name}:</label>
            <input type="text" id="{input_id}" placeholder="filename.ext" value="{value_attr}" style="width:100px;" />
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
    {field_var}.addEventListener("change", () => {{
      {obj_var}.value = {field_var}.checked;
    }});''',
        "txt": f'''
    {field_var}.addEventListener("input", () => {{
      {obj_var}.value = {field_var}.value;
    }});''',
        "col": f'''
    {field_var}.addEventListener("input", () => {{
      let hex = {field_var}.value.replace("#", "");
      let argb = parseInt("FF" + hex.toUpperCase(), 16);
      {obj_var}.value = argb;
    }});'''
    }
    return js_configs.get(input_type, "")

def collect_input_fields(row, button_id):
    """Collect all input fields for a row"""
    inputs_html = []
    for i in INPUT_RANGE:
        input_value = row.get(f"input{i}")
        if input_value is not None and input_value.strip() != "":
            inputs_html.append(parse_input_field(input_value, i, button_id))
    return "".join(inputs_html)

def make_main_canvas(idx, row):
    canvas_id = f"canvas{idx}"
    button_id = f"btn{idx}"

    # Build button HTML
    button_html = ""
    if row.get("trigger"):
        button_html = f'<button id="{button_id}" class="rive-btn" style="margin-left:auto;">Trigger</button>'

    # Collect input fields (below the row)
    inputs_html = collect_input_fields(row, button_id)
    if inputs_html:
        inputs_html = f'''
        <div class="controls-column" style="display:flex;flex-direction:column;align-items:flex-end;gap:8px;margin-top:8px;">
            {inputs_html}
        </div>
        '''
    else:
        inputs_html = ""

    width, height = scale_dimensions(row["width"], row["height"])
    desc = f'''
      <div style="display: flex; flex-direction: column; align-items: stretch;">
        <div style="display: flex; align-items: center; width: 100%;">
          <div>{make_main_link(row)}</div>
          {button_html}
        </div>
        {inputs_html}
      </div>
    '''
    return f'''
      <div class="animation-container">
        <canvas id="{canvas_id}" width="{width}" height="{height}"></canvas>
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

def generate_text_input_js(row, prefix, rive_var):
    """Generate JS for ViewModel-based inputs (txt, col, v_num, v_bol, img, list)."""
    js_parts = []
    has_vmi_inputs = False
    for i in INPUT_RANGE:
        input_value = row.get(f"input{i}")
        if not input_value:
            continue
        input_type, name_spec, _default = parse_input_spec(input_value)
        input_name = name_spec  # ensure name available for non-list types
        list_match = None
        if input_type == "list" and name_spec:
            list_match = re.match(r'^([^\[]+)\[(.+)\]$', name_spec)
        input_id = f"{prefix}_input{i}"
        field_var = f"inputField{prefix.title()}_{i}"
        if input_type in ("txt", "col", "v_num", "v_bol", "img"):
            has_vmi_inputs = True
            if input_type == "txt":
                js_parts.append(f"    let {field_var} = document.getElementById(\"{input_id}\");\n")
                js_parts.append(f"""    if ({field_var} && vmi) {{
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
    if has_vmi_inputs:
        js_parts.insert(0, f"    const vmi = {rive_var}.viewModelInstance;\n")
    return "".join(js_parts)

def generate_rive_js_block(var_name, canvas_id, src, artboard, state_machine, trigger, input_prefix, row):
    artboard_line = f'artboard: "{artboard}",' if artboard else ""
    state_machine_line = f' stateMachines: "{state_machine}",' if state_machine else ""
    js = [f'''
const {var_name} = new rive.Rive({{
  src: "{src}",
  canvas: document.getElementById("{canvas_id}"),
  autoplay: true, autoBind: true,{artboard_line}{state_machine_line}
  onLoad: () => {{
    {var_name}.resizeDrawingSurfaceToCanvas();
''']

    # Text and color input handling (will only emit vmi if needed)
    js.append(generate_text_input_js(row, input_prefix, var_name))

    # State machine inputs and triggers
    if state_machine:
        js.append(f'    const inputs = {var_name}.stateMachineInputs("{state_machine}");\n')
        if trigger:
            js.append(f'''    let triggerInput = inputs.find(input => input.name === "{trigger}");
    if (triggerInput) {{
      document.getElementById("{input_prefix}").addEventListener("click", () => triggerInput.fire());
    }}
''')
        for i in INPUT_RANGE:
            input_value = row.get(f"input{i}")
            if not input_value or input_value.strip() == "":
                continue
            input_type, input_name, _default = parse_input_spec(input_value)
            # Skip ViewModel & list handled above
            if input_type in ("txt", "col", "v_num", "v_bol", "list"):
                continue
            input_id = f"{input_prefix}_input{i}"
            field_var = f'inputField_{input_prefix}_{i}'
            obj_var = f'inputObj_{input_prefix}_{i}'
            js.append(f'    let {field_var} = document.getElementById("{input_id}");\n')
            js.append(f'    let {obj_var} = inputs.find(input => input.name === "{input_name}");\n')
            if input_type == "num":
                js.append(f'''    if ({field_var} && {obj_var}) {{
      {field_var}.addEventListener("input", () => {{
        let val = parseFloat({field_var}.value);
        if (!isNaN(val)) {obj_var}.value = val;
      }});
    }}
''')
            elif input_type == "bol":
                js.append(f'''    if ({field_var} && {obj_var}) {{
      {field_var}.addEventListener("change", () => {{
        {obj_var}.value = {field_var}.checked;
      }});
    }}
''')
            elif input_type == "txt":
                # Already handled by vmi above, skip here
                continue
            elif input_type == "col":
                # Already handled by vmi above, skip here
                continue
    js.append('  },\n});\n')
    return "".join(js)

def make_script(rows):
    script_parts = ["<script>\n"]
    for idx, row in enumerate(rows):
        canvas_id = f"canvas{idx}"
        button_id = f"btn{idx}"
        src = f"riv/{row['src']}"
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
                row=row
            )
        )

    # Canvas sizing and auto-trigger
    script_parts.append('''
document.querySelectorAll('canvas').forEach(canvas => {
  canvas.style.width = canvas.width + "px";
  canvas.style.height = canvas.height + "px";
});

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
    display_name = get_display_name(row["src"])
    # Compose size from width and height
    size_str = f'{row["width"]}px × {row["height"]}px'
    parts = [
        f'<a href="../riv/{row["src"]}" target="_blank" style="color: white;">{display_name}</a><br>',
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

    # Add all non-empty inputs
    for i in INPUT_RANGE:
        input_value = row.get(f"input{i}")
        if input_value and input_value.strip() != "":
            parts.append(f'Input: {input_value.strip()}<br>')

    parts.extend([
        f'Duration: {row["duration"]}s<br>',
        f'Loop: {row["loop"]}<br>',
        f'Background: {row["background"]}<br>'
    ])

    return "".join(parts)

def make_animation_inputs(row, prefix):
    """Generate animation input HTML"""
    html_parts = []
    for i in INPUT_RANGE:
        input_value = row.get(f"input{i}")
        if input_value is not None and input_value.strip() != "":
            html_parts.append(parse_input_field(input_value, i, prefix))
    return "".join(html_parts)

def check_preview_exists(row):
    """Check if preview file exists"""
    src_base = os.path.splitext(row["src"])[0]
    preview_file = f'{src_base}_preview.riv'
    preview_path = os.path.join(script_dir, "riv", preview_file)
    return f'../riv/{preview_file}' if os.path.exists(preview_path) else None

def make_animation_page(row):
    page_name = os.path.splitext(row["src"])[0] + ".html"
    main_rive = f'../riv/{row["src"]}'
    preview_rive = check_preview_exists(row)
    
    html_parts = [get_html_head()]
    
    # Generate main content based on preview existence
    if (preview_rive):
        html_parts.append(generate_dual_animation_html(row, preview_rive))
    else:
        html_parts.append(generate_single_animation_html(row))
    
    # Generate JavaScript
    html_parts.append(generate_animation_js(row, main_rive, preview_rive))
    html_parts.append(html_foot)
    
    # Write file
    with open(os.path.join(pages_dir, page_name), "w", encoding="utf-8") as f:
        f.write("".join(html_parts))

def generate_single_animation_html(row):
    """Generate HTML for single animation layout"""
    return f'''
    <div class="animation-container">
      <canvas id="main_canvas" width="{row["width"]}" height="{row["height"]}"></canvas>
      <div class="description">
        <div>
          <div>{make_description_html(row)}</div>
          <div style="display: flex; flex-direction: column; align-items: flex-end; margin-top: 16px; gap: 12px;">
            {'<button id="btn_main" class="rive-btn">Trigger</button>' if row.get("trigger") else ''}
            {make_animation_inputs(row, "btn_main")}
          </div>
        </div>
      </div>
    </div>
'''

def generate_dual_animation_html(row, preview_rive):
    """Generate HTML for dual animation layout"""
    return f'''
    <div class="animation-row" style="display: flex; gap: 32px; align-items: flex-start;">
      <div class="animation-container">
        <canvas id="main_canvas" width="{row["width"]}" height="{row["height"]}"></canvas>
        <div class="description">
          <div>
            <div>{make_description_html(row)}</div>
            <div style="display: flex; flex-direction: column; align-items: flex-end; margin-top: 16px; gap: 12px;">
              {'<button id="btn_main" class="rive-btn">Trigger</button>' if row.get("trigger") else ''}
              {make_animation_inputs(row, "btn_main")}
            </div>
          </div>
        </div>
      </div>
      <div class="animation-container">
        <canvas id="preview_canvas" width="{row["width"]}" height="{row["height"]}"></canvas>
        <div class="description">
          Preview:<br>
          <div style="display: flex; flex-direction: column; align-items: flex-end; margin-top: 16px; gap: 12px;">
            {'<button id="btn_preview" class="rive-btn">Trigger</button>' if row.get("trigger") else ''}
            {make_animation_inputs(row, "btn_preview")}
          </div>
        </div>
      </div>
    </div>
'''

def generate_animation_js(row, main_rive, preview_rive):
    """Generate JavaScript for animation page"""
    js_parts = ['<script>\n']
    
    # Main animation
    js_parts.append(f'''
const mainRive = new rive.Rive({{
  src: "{main_rive}",
  canvas: document.getElementById("main_canvas"),
  autoplay: true,autoBind: true,{f' artboard: "{row["artboard"]}",' if row.get("artboard") else ""}{f' stateMachines: "{row["state_machine"]}",' if row.get("state_machine") else ""}
  onLoad: () => {{
    mainRive.resizeDrawingSurfaceToCanvas();
''')
    
    # Handle text inputs in onLoad for main
    js_parts.append(generate_text_input_js(row, "btn_main", "mainRive"))
    js_parts.append('  },\n});\n')
    
    # Main animation controls
    js_parts.append(generate_animation_controls_js(row, "main", "mainRive"))
    
    # Preview animation if exists
    if preview_rive:
        js_parts.append(generate_preview_animation_js(row, preview_rive))
    
    js_parts.append('''
document.querySelectorAll('canvas').forEach(canvas => {
  canvas.style.width = canvas.width + "px";
  canvas.style.height = canvas.height + "px";
});
</script>
''')
    
    return "".join(js_parts)

def generate_animation_controls_js(row, canvas_type, rive_var):
    """Generate animation control JavaScript"""
    js_parts = []
    
    # Trigger handling
    if row.get("trigger"):
        js_parts.append(f'''
let triggerInput{canvas_type.title()};
{rive_var}.on("load", () => {{
  const inputs = {rive_var}.stateMachineInputs("{row["state_machine"]}");
  triggerInput{canvas_type.title()} = inputs.find(input => input.name === "{row["trigger"]}");
}});
document.getElementById("btn_{canvas_type}").addEventListener("click", () => {{
  if (triggerInput{canvas_type.title()}) {{
    triggerInput{canvas_type.title()}.fire();
  }}
}});
''')
    
    # Input handling for num/bool
    for i in INPUT_RANGE:
        input_value = row.get(f"input{i}")
        if not input_value:
            continue
        
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
        # v_num, txt, col, list skipped (handled via ViewModel)
    return "".join(js_parts)

def generate_preview_animation_js(row, preview_rive):
    """Generate preview animation JavaScript"""
    js_parts = [f'''
const previewRive = new rive.Rive({{
  src: "{preview_rive}",
  canvas: document.getElementById("preview_canvas"),
  autoplay: true, autoBind: true,{f' artboard: "{row["artboard"]}",' if row.get("artboard") else ""}{f' stateMachines: "{row["state_machine"]}",' if row.get("state_machine") else ""}
  onLoad: () => {{
    previewRive.resizeDrawingSurfaceToCanvas();
''']
    
    js_parts.append(generate_text_input_js(row, "btn_preview", "previewRive"))
    js_parts.append('  },\n});\n')
    js_parts.append(generate_animation_controls_js(row, "preview", "previewRive"))
    
    return "".join(js_parts)

def make_pagination_buttons(current_page, total_pages):
    buttons = []
    for i in range(total_pages):
        filename = "index.html" if i == 0 else f"page{i}.html"
        label = str(i + 1)
        
        if i == current_page:
            buttons.append(f'<button class="rive-btn" style="background:#e0e0e0;color:#333;">{label}</button>')
        else:
            buttons.append(f'<a href="{filename}"><button class="rive-btn">{label}</button></a>')
    
    return '<div style="margin: 24px 0; text-align:center;">' + " ".join(buttons) + "</div>"

def write_main_page(page_rows, page_idx, total_pages):
    filename = output_html if page_idx == 0 else os.path.join(script_dir, f"page{page_idx}.html")
    
    with open(filename, "w", encoding="utf-8") as f:
        content_parts = [
            get_html_head(),
            "".join(make_main_canvas(idx, row) for idx, row in enumerate(page_rows)),
            "</div>\n",
            make_script(page_rows),
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
    with open(csv_path, newline='', encoding='utf-8') as csvfile:
        reader = csv.DictReader(csvfile)
        rows = list(reader)[::-1]

    # Normalize state_machine field
    for row in rows:
        if not row.get("state_machine") or row["state_machine"].strip() == "":
            row["state_machine"] = "State Machine 1"

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