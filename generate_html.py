import os
import csv
import re

script_dir = os.path.dirname(os.path.abspath(__file__))
csv_path = os.path.join(script_dir, "videos.csv")
output_html = os.path.join(script_dir, "index.html")
head_html_path = os.path.join(script_dir, "head.html")
pages_dir = os.path.join(script_dir, "pages")
os.makedirs(pages_dir, exist_ok=True)

with open(head_html_path, "r", encoding="utf-8") as head_file:
    html_head = head_file.read()

html_foot = """
    </div>
</body>
</html>
"""

SCALE_TO_200PX = True  # Set to True to scale all animations to 200px width proportionally (main page only)

def scale_dimensions(width, height):
    if not SCALE_TO_200PX:
        return width, height
    try:
        width = int(width)
        height = int(height)
    except Exception:
        return width, height
    if width == 200:
        return width, height
    scale = 200 / width
    return 200, int(round(height * scale))

def get_display_name(src):
    # Remove extension
    name = os.path.splitext(src)[0]
    # Remove version patterns like _v1, _v10, _v2a, etc.
    name = re.sub(r'_v\d+[a-zA-Z0-9]*', '', name)
    # Replace underscores with spaces
    name = name.replace('_', ' ')
    return name

def make_main_link(row):
    page_name = os.path.splitext(row["src"])[0] + ".html"
    display_name = get_display_name(row["src"])
    return f'<a href="pages/{page_name}" style="color: #464646;">{display_name}</a>'

def parse_input_field(input_value, input_idx, button_id):
    if not input_value:
        return ""
    if ":" in input_value:
        input_type, input_name = input_value.split(":", 1)
    else:
        input_type, input_name = "num", input_value  # Default to number if no type
    input_html = ""
    input_id = f"{button_id}_input{input_idx}"
    label = input_name
    if input_type == "num":
        input_html = f'<label style="margin-right:4px;">{label}:</label><input type="number" id="{input_id}" value="80" style="width:50px; margin-top: 8px;" />'
    elif input_type == "txt":
        input_html = f'<label style="margin-right:4px;">{label}:</label><input type="text" id="{input_id}" style="width:80px; margin-top: 8px;" />'
    elif input_type == "bool":
        input_html = f'<label style="margin-right:4px;">{label}:</label><input type="checkbox" id="{input_id}" style="margin-top: 8px;" />'
    return "<br>" + input_html

def make_main_canvas(idx, row):
    canvas_id = f"canvas{idx}"
    button_id = f"btn{idx}"
    button_html = ""
    # Always generate button and input if trigger/input1..input5 exists
    if row.get("trigger"):
        button_html += f'<button id="{button_id}" class="rive-btn">Trigger</button>'
    # Handle multiple inputs
    for i in range(1, 6):
        input_col = f"input{i}"
        input_value = row.get(input_col)
        if input_value:
            button_html += parse_input_field(input_value, i, button_id)
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

def make_script(rows):
    script = "<script>\n"
    for idx, row in enumerate(rows):
        canvas_id = f"canvas{idx}"
        button_id = f"btn{idx}"
        src = f"riv/{row['src']}"
        state_machine = row["state_machine"] if "State Machine" in row["state_machine"] else ""
        artboard = row["artboard"] if row.get("artboard") else ""
        artboard_line = f'artboard: "{artboard}",' if artboard else ""
        state_machine_line = f' stateMachines: "{state_machine}",' if state_machine else ""
        script += f'''
const r{idx} = new rive.Rive({{
  src: "{src}",
  canvas: document.getElementById("{canvas_id}"),
  autoplay: true, autoBind: true,{artboard_line}{state_machine_line}
  onLoad: () => {{
    r{idx}.resizeDrawingSurfaceToCanvas();
  }},
}});
'''
        if row.get("trigger"):
            script += f'''
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
        # Handle multiple inputs
        for i in range(1, 6):
            input_col = f"input{i}"
            input_value = row.get(input_col)
            if input_value:
                if ":" in input_value:
                    input_type, input_name = input_value.split(":", 1)
                else:
                    input_type, input_name = "num", input_value
                input_id = f"{button_id}_input{i}"
                script += f'''
let inputObj{idx}_{i};
let inputField{idx}_{i} = document.getElementById("{input_id}");
r{idx}.on("load", () => {{
  const inputs = r{idx}.stateMachineInputs("{state_machine}");
  inputObj{idx}_{i} = inputs.find(input => input.name === "{input_name}");
  if (inputField{idx}_{i} && inputObj{idx}_{i}) {{
'''
                if input_type == "num":
                    script += f'''
    inputField{idx}_{i}.addEventListener("input", () => {{
      let val = parseFloat(inputField{idx}_{i}.value);
      if (!isNaN(val)) inputObj{idx}_{i}.value = val;
    }});
'''
                elif input_type == "txt":
                    script += f'''
    inputField{idx}_{i}.addEventListener("input", () => {{
      inputObj{idx}_{i}.value = inputField{idx}_{i}.value;
    }});
'''
                elif input_type == "bool":
                    script += f'''
    inputField{idx}_{i}.addEventListener("change", () => {{
      inputObj{idx}_{i}.value = inputField{idx}_{i}.checked;
    }});
'''
                script += f'''
  }}
}});
'''
    script += '''
document.querySelectorAll('canvas').forEach(canvas => {
  canvas.style.width = canvas.width + "px";
  canvas.style.height = canvas.height + "px";
});
</script>
'''
    return script

def make_description_html(row):
    display_name = get_display_name(row["src"])
    desc = f'<a href="../riv/{row["src"]}" target="_blank" style="color: white;">{display_name}</a><br>'
    desc += f'Size: {row["size"]}<br>'
    desc += f'State Machine: {row["state_machine"]}<br>'
    if row["artboard"]:
        desc += f'Artboard: {row["artboard"]}<br>'
    if row["trigger"]:
        desc += f'Trigger: {row["trigger"]}<br>'
    if row["input1"]:
        desc += f'Input: {row["input1"]}<br>'
    desc += f'Duration: {row["duration"]}s<br>'
    desc += f'Loop: {row["loop"]}<br>'
    desc += f'Background: {row["background"]}<br>'
    return desc

def make_animation_inputs(row, prefix):
    html = ""
    for i in range(1, 6):
        input_col = f"input{i}"
        input_value = row.get(input_col)
        if input_value:
            if ":" in input_value:
                input_type, input_name = input_value.split(":", 1)
            else:
                input_type, input_name = "num", input_value
            input_id = f"{prefix}_input{i}"
            label = input_name
            if input_type == "num":
                html += f'<br><label style="margin-right:4px;">{label}:</label><input type="number" id="{input_id}" value="80" style="width:50px; margin-top: 8px;" />'
            elif input_type == "txt":
                html += f'<br><label style="margin-right:4px;">{label}:</label><input type="text" id="{input_id}" style="width:80px; margin-top: 8px;" />'
            elif input_type == "bool":
                html += f'<br><label style="margin-right:4px;">{label}:</label><input type="checkbox" id="{input_id}" style="margin-top: 8px;" />'
    return html

def make_animation_page(row):
    # Per-animation HTML page with description and preview if exists
    page_name = os.path.splitext(row["src"])[0] + ".html"
    main_rive = f'../riv/{row["src"]}'
    preview_rive = None
    src_base = os.path.splitext(row["src"])[0]
    preview_file = f'{src_base}_preview.riv'
    preview_path = os.path.join(script_dir, "riv", preview_file)
    if os.path.exists(preview_path):
        preview_rive = f'../riv/{preview_file}'

    html = html_head
    # Main + Preview animation block (side by side if preview exists)
    if preview_rive:
        html += f'''
    <div class="animation-row" style="display: flex; gap: 32px; align-items: flex-start;">
      <div class="animation-container">
        <canvas id="main_canvas" width="{row["width"]}" height="{row["height"]}"></canvas>
        <div class="description">
          <div style="display: flex; align-items: flex-start; justify-content: space-between;">
            <div>{make_description_html(row)}</div>
            <div>
'''
        if row.get("trigger"):
            html += f'<button id="btn_main" class="rive-btn">Trigger</button>'
        html += make_animation_inputs(row, "btn_main")
        html += '''
            </div>
          </div>
        </div>
      </div>
      <div class="animation-container">
        <canvas id="preview_canvas" width="{0}" height="{1}"></canvas>
        <div class="description">
          Preview:<br>
'''.format(row["width"], row["height"])
        if row.get("trigger"):
            html += f'<button id="btn_preview" class="rive-btn">Trigger</button>'
        html += make_animation_inputs(row, "btn_preview")
        html += "<br>"
        html += '''
        </div>
      </div>
    </div>
'''
    else:
        html += f'''
    <div class="animation-container">
      <canvas id="main_canvas" width="{row["width"]}" height="{row["height"]}"></canvas>
      <div class="description">
        <div style="display: flex; align-items: flex-start; justify-content: space-between;">
          <div>{make_description_html(row)}</div>
          <div>
'''
        if row.get("trigger"):
            html += f'<button id="btn_main" class="rive-btn">Trigger</button>'
        html += make_animation_inputs(row, "btn_main")
        html += '''
          </div>
        </div>
      </div>
    </div>
'''

    # --- JS Section ---
    html += '''
<script>
const mainRive = new rive.Rive({
  src: "%s",
  canvas: document.getElementById("main_canvas"),
  autoplay: true,autoBind: true,%s%s
  onLoad: () => {
    mainRive.resizeDrawingSurfaceToCanvas();
''' % (
        main_rive,
        f' artboard: "{row["artboard"]}",' if row.get("artboard") else "",
        f' stateMachines: "{row["state_machine"]}",' if row.get("state_machine") else ""
    )

    # Handle txt inputs directly in onLoad
    for i in range(1, 6):
        input_col = f"input{i}"
        input_value = row.get(input_col)
        if input_value and ":" in input_value and input_value.split(":", 1)[0] == "txt":
            input_type, input_name = input_value.split(":", 1)
            input_id = f"btn_main_input{i}"
            html += f'''
    const vmi = mainRive.viewModelInstance;
    let inputFieldMain_{i} = document.getElementById("{input_id}");
    if (inputFieldMain_{i} && vmi) {{
      inputFieldMain_{i}.addEventListener("input", () => {{
        vmi.string("{input_name}").value = inputFieldMain_{i}.value;
      }});
    }}
'''

    html += '''
  },
});
'''

    # Main animation buttons/inputs JS (trigger and non-txt inputs)
    if row.get("trigger"):
        html += f'''
let triggerInputMain;
mainRive.on("load", () => {{
  const inputs = mainRive.stateMachineInputs("{row["state_machine"]}");
  triggerInputMain = inputs.find(input => input.name === "{row["trigger"]}");
}});
document.getElementById("btn_main").addEventListener("click", () => {{
  if (triggerInputMain) {{
    triggerInputMain.fire();
  }}
}});
'''
    # Handle num/bool inputs for main animation
    for i in range(1, 6):
        input_col = f"input{i}"
        input_value = row.get(input_col)
        if input_value:
            if ":" in input_value:
                input_type, input_name = input_value.split(":", 1)
            else:
                input_type, input_name = "num", input_value
            input_id = f"btn_main_input{i}"
            if input_type == "num" or input_type == "bool":
                html += f'''
let inputFieldMain_{i} = document.getElementById("{input_id}");
mainRive.on("load", () => {{
  const inputs = mainRive.stateMachineInputs("{row["state_machine"]}");
  let inputObjMain_{i} = inputs.find(input => input.name === "{input_name}");
  if (inputFieldMain_{i} && inputObjMain_{i}) {{
'''
                if input_type == "num":
                    html += f'''
    inputFieldMain_{i}.addEventListener("input", () => {{
      let val = parseFloat(inputFieldMain_{i}.value);
      if (!isNaN(val)) inputObjMain_{i}.value = val;
    }});
'''
                elif input_type == "bool":
                    html += f'''
    inputFieldMain_{i}.addEventListener("change", () => {{
      inputObjMain_{i}.value = inputFieldMain_{i}.checked;
    }});
'''
                html += f'''
  }}
}});
'''

    # --- Preview animation JS and buttons/inputs ---
    if preview_rive:
        html += '''
const previewRive = new rive.Rive({
  src: "%s",
  canvas: document.getElementById("preview_canvas"),
  autoplay: true, autoBind: true,%s%s
  onLoad: () => {
    previewRive.resizeDrawingSurfaceToCanvas();
''' % (
        preview_rive,
        f' artboard: "{row["artboard"]}",' if row.get("artboard") else "",
        f' stateMachines: "{row["state_machine"]}",' if row.get("state_machine") else ""
    )

        # Handle txt inputs for preview directly in onLoad
        for i in range(1, 6):
            input_col = f"input{i}"
            input_value = row.get(input_col)
            if input_value and ":" in input_value and input_value.split(":", 1)[0] == "txt":
                input_type, input_name = input_value.split(":", 1)
                input_id = f"btn_preview_input{i}"
                html += f'''
    const vmi = previewRive.viewModelInstance;
    let inputFieldPreview_{i} = document.getElementById("{input_id}");
    if (inputFieldPreview_{i} && vmi) {{
      inputFieldPreview_{i}.addEventListener("input", () => {{
        vmi.string("{input_name}").value = inputFieldPreview_{i}.value;
      }});
    }}
'''

        html += '''
  },
});
'''

        if row.get("trigger"):
            html += f'''
let triggerInputPreview;
previewRive.on("load", () => {{
  const inputs = previewRive.stateMachineInputs("{row["state_machine"]}");
  triggerInputPreview = inputs.find(input => input.name === "{row["trigger"]}");
}});
document.getElementById("btn_preview").addEventListener("click", () => {{
  if (triggerInputPreview) {{
    triggerInputPreview.fire();
  }}
}});
'''
        # Handle num/bool inputs for preview animation
        for i in range(1, 6):
            input_col = f"input{i}"
            input_value = row.get(input_col)
            if input_value:
                if ":" in input_value:
                    input_type, input_name = input_value.split(":", 1)
                else:
                    input_type, input_name = "num", input_value
                input_id = f"btn_preview_input{i}"
                if input_type == "num" or input_type == "bool":
                    html += f'''
let inputFieldPreview_{i} = document.getElementById("{input_id}");
previewRive.on("load", () => {{
  const inputs = previewRive.stateMachineInputs("{row["state_machine"]}");
  let inputObjPreview_{i} = inputs.find(input => input.name === "{input_name}");
  if (inputFieldPreview_{i} && inputObjPreview_{i}) {{
'''
                    if input_type == "num":
                        html += f'''
    inputFieldPreview_{i}.addEventListener("input", () => {{
      let val = parseFloat(inputFieldPreview_{i}.value);
      if (!isNaN(val)) inputObjPreview_{i}.value = val;
    }});
'''
                    elif input_type == "bool":
                        html += f'''
    inputFieldPreview_{i}.addEventListener("change", () => {{
      inputObjPreview_{i}.value = inputFieldPreview_{i}.checked;
    }});
'''
                    html += f'''
  }}
}});
'''

    html += '''
document.querySelectorAll('canvas').forEach(canvas => {
  canvas.style.width = canvas.width + "px";
  canvas.style.height = canvas.height + "px";
});
</script>
'''
    html += html_foot
    # Write to file
    with open(os.path.join(pages_dir, page_name), "w", encoding="utf-8") as f:
        f.write(html)

ANIMATIONS_PER_PAGE = 8

def make_pagination_buttons(current_page, total_pages):
    buttons = []
    for i in range(total_pages):
        if i == 0:
            filename = "index.html"
        else:
            filename = f"page{i}.html"
        label = str(i + 1)
        if i == current_page:
            # Highlight current page
            buttons.append(f'<button class="rive-btn" style="background:#e0e0e0;color:#333;">{label}</button>')
        else:
            buttons.append(f'<a href="{filename}"><button class="rive-btn">{label}</button></a>')
    return '<div style="margin: 24px 0; text-align:center;">' + " ".join(buttons) + "</div>"

def write_main_page(page_rows, page_idx, total_pages):
    if page_idx == 0:
        filename = output_html
    else:
        filename = os.path.join(script_dir, f"page{page_idx}.html")
    with open(filename, "w", encoding="utf-8") as f:
        f.write(html_head)
        # Removed top pagination buttons
        for idx, row in enumerate(page_rows):
            f.write(make_main_canvas(idx, row))
        f.write("</div>\n")
        f.write(make_script(page_rows))
        f.write(make_pagination_buttons(page_idx, total_pages))
        f.write(html_foot)

with open(csv_path, newline='', encoding='utf-8') as csvfile:
    reader = csv.DictReader(csvfile)
    rows = list(reader)[::-1]

# Generate per-animation pages
for row in rows:
    make_animation_page(row)

# Pagination logic
total_pages = (len(rows) + ANIMATIONS_PER_PAGE - 1) // ANIMATIONS_PER_PAGE
for page_idx in range(total_pages):
    start = page_idx * ANIMATIONS_PER_PAGE
    end = start + ANIMATIONS_PER_PAGE
    page_rows = rows[start:end]
    write_main_page(page_rows, page_idx, total_pages)

print(f"Generated {output_html}, {total_pages-1} extra pages, and {len(rows)} animation pages in 'pages/'")