import os
import csv
import re
from functools import lru_cache

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
INPUT_RANGE = range(1, 5)  # Constant for input iteration

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
    if ":" in input_value:
        return input_value.split(":", 1)
    return "num", input_value

def parse_input_field(input_value, input_idx, button_id):
    input_type, input_name = parse_input_type_name(input_value)
    if not input_type:
        return ""
    
    input_id = f"{button_id}_input{input_idx}"
    
    input_configs = {
        "num": f'<input type="number" id="{input_id}" value="80" style="width:50px; margin-top: 8px;" />',
        "txt": f'<input type="text" id="{input_id}" style="width:80px; margin-top: 8px;" />',
        "bool": f'<input type="checkbox" id="{input_id}" style="margin-top: 8px;" />'
    }
    
    input_html = input_configs.get(input_type, "")
    if input_html:
        return f'<br><label style="margin-right:4px;">{input_name}:</label>{input_html}'
    return ""

def make_input_js(input_type, input_name, input_id, obj_var, field_var):
    js_configs = {
        "num": f'''
    {field_var}.addEventListener("input", () => {{
      let val = parseFloat({field_var}.value);
      if (!isNaN(val)) {obj_var}.value = val;
    }});''',
        "bool": f'''
    {field_var}.addEventListener("change", () => {{
      {obj_var}.value = {field_var}.checked;
    }});''',
        "txt": f'''
    {field_var}.addEventListener("input", () => {{
      {obj_var}.value = {field_var}.value;
    }});'''
    }
    return js_configs.get(input_type, "")

def collect_input_fields(row, button_id):
    """Collect all input fields for a row"""
    inputs_html = []
    for i in INPUT_RANGE:
        input_value = row.get(f"input{i}")
        if input_value:
            inputs_html.append(parse_input_field(input_value, i, button_id))
    return "".join(inputs_html)

def make_main_canvas(idx, row):
    canvas_id = f"canvas{idx}"
    button_id = f"btn{idx}"
    
    # Build button HTML
    button_html = ""
    if row.get("trigger"):
        button_html += f'<button id="{button_id}" class="rive-btn">Trigger</button>'
    
    button_html += collect_input_fields(row, button_id)
    
    width, height = scale_dimensions(row["width"], row["height"])
    desc = f'''
      <div style="display: flex; align-items: flex-start; justify-content: space-between;">
        <div>{make_main_link(row)}</div>
        <div>{button_html}</div>
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

def generate_trigger_js(idx, row):
    """Generate trigger JavaScript"""
    if not row.get("trigger"):
        return ""
    
    button_id = f"btn{idx}"
    state_machine = row.get("state_machine", "")
    
    return f'''
let triggerInput{idx};
r{idx}.on("load", () => {{
  const inputs = r{idx}.stateMachineInputs("{state_machine}");
  triggerInput{idx} = inputs.find(input => input.name === "{row["trigger"]}");
}});
document.getElementById("{button_id}").addEventListener("click", () => {{
  if (triggerInput{idx}) {{
    triggerInput{idx}.fire();
  }}
}});
'''

def generate_inputs_js(idx, row):
    """Generate input handling JavaScript"""
    button_id = f"btn{idx}"
    state_machine = row.get("state_machine", "")
    js_parts = []
    
    for i in INPUT_RANGE:
        input_value = row.get(f"input{i}")
        if not input_value:
            continue
            
        input_type, input_name = parse_input_type_name(input_value)
        input_id = f"{button_id}_input{i}"
        
        js_part = f'''
let inputObj{idx}_{i};
let inputField{idx}_{i} = document.getElementById("{input_id}");
r{idx}.on("load", () => {{
  const inputs = r{idx}.stateMachineInputs("{state_machine}");
  inputObj{idx}_{i} = inputs.find(input => input.name === "{input_name}");
  if (inputField{idx}_{i} && inputObj{idx}_{i}) {{
{make_input_js(input_type, input_name, input_id, f"inputObj{idx}_{i}", f"inputField{idx}_{i}")}
  }}
}});
'''
        js_parts.append(js_part)
    
    return "".join(js_parts)

def make_script(rows):
    script_parts = ["<script>\n"]
    
    for idx, row in enumerate(rows):
        script_parts.extend([
            generate_rive_config(idx, row),
            generate_trigger_js(idx, row),
            generate_inputs_js(idx, row)
        ])
    
    script_parts.append('''
document.querySelectorAll('canvas').forEach(canvas => {
  canvas.style.width = canvas.width + "px";
  canvas.style.height = canvas.height + "px";
});
</script>
''')
    return "".join(script_parts)

def make_description_html(row):
    display_name = get_display_name(row["src"])
    parts = [
        f'<a href="../riv/{row["src"]}" target="_blank" style="color: white;">{display_name}</a><br>',
        f'Size: {row["size"]}<br>',
        f'State Machine: {row["state_machine"]}<br>'
    ]
    
    optional_fields = [
        ("artboard", "Artboard"),
        ("trigger", "Trigger"),
        ("input1", "Input")
    ]
    
    for field, label in optional_fields:
        if row.get(field):
            parts.append(f'{label}: {row[field]}<br>')
    
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
        if not input_value:
            continue
            
        input_type, input_name = parse_input_type_name(input_value)
        input_id = f"{prefix}_input{i}"
        
        input_configs = {
            "num": f'<br><label style="margin-right:4px;">{input_name}:</label><input type="number" id="{input_id}" value="80" style="width:50px; margin-top: 8px;" />',
            "txt": f'<br><label style="margin-right:4px;">{input_name}:</label><input type="text" id="{input_id}" style="width:80px; margin-top: 8px;" />',
            "bool": f'<br><label style="margin-right:4px;">{input_name}:</label><input type="checkbox" id="{input_id}" style="margin-top: 8px;" />'
        }
        
        html_parts.append(input_configs.get(input_type, ""))
    
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
    if preview_rive:
        html_parts.append(generate_dual_animation_html(row, preview_rive))
    else:
        html_parts.append(generate_single_animation_html(row))
    
    # Generate JavaScript
    html_parts.append(generate_animation_js(row, main_rive, preview_rive))
    html_parts.append(html_foot)
    
    # Write file
    with open(os.path.join(pages_dir, page_name), "w", encoding="utf-8") as f:
        f.write("".join(html_parts))

def generate_dual_animation_html(row, preview_rive):
    """Generate HTML for dual animation layout"""
    return f'''
    <div class="animation-row" style="display: flex; gap: 32px; align-items: flex-start;">
      <div class="animation-container">
        <canvas id="main_canvas" width="{row["width"]}" height="{row["height"]}"></canvas>
        <div class="description">
          <div style="display: flex; align-items: flex-start; justify-content: space-between;">
            <div>{make_description_html(row)}</div>
            <div>
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
          {'<button id="btn_preview" class="rive-btn">Trigger</button>' if row.get("trigger") else ''}
          {make_animation_inputs(row, "btn_preview")}<br>
        </div>
      </div>
    </div>
'''

def generate_single_animation_html(row):
    """Generate HTML for single animation layout"""
    return f'''
    <div class="animation-container">
      <canvas id="main_canvas" width="{row["width"]}" height="{row["height"]}"></canvas>
      <div class="description">
        <div style="display: flex; align-items: flex-start; justify-content: space-between;">
          <div>{make_description_html(row)}</div>
          <div>
            {'<button id="btn_main" class="rive-btn">Trigger</button>' if row.get("trigger") else ''}
            {make_animation_inputs(row, "btn_main")}
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

def generate_text_input_js(row, prefix, rive_var):
    """Generate text input handling JavaScript"""
    js_parts = []
    for i in INPUT_RANGE:
        input_value = row.get(f"input{i}")
        if not input_value:
            continue
        
        input_type, input_name = parse_input_type_name(input_value)
        if input_type == "txt":
            input_id = f"{prefix}_input{i}"
            js_parts.append(f'''
    const vmi = {rive_var}.viewModelInstance;
    let inputField{prefix.title()}_{i} = document.getElementById("{input_id}");
    if (inputField{prefix.title()}_{i} && vmi) {{
      inputField{prefix.title()}_{i}.addEventListener("input", () => {{
        vmi.string("{input_name}").value = inputField{prefix.title()}_{i}.value;
      }});
    }}
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
        
        input_type, input_name = parse_input_type_name(input_value)
        if input_type in ["num", "bool"]:
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

# Main execution
def main():
    with open(csv_path, newline='', encoding='utf-8') as csvfile:
        reader = csv.DictReader(csvfile)
        rows = list(reader)[::-1]

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
    main()