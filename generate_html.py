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

def make_main_link(row):
    # Link to the per-animation page
    page_name = os.path.splitext(row["src"])[0] + ".html"
    # Remove version suffix like _v1, _v12, _v123 from the name for display
    display_name = re.sub(r'_v\d+$', '', row["name"])
    return f'<a href="pages/{page_name}" style="color: #464646;">{display_name}</a>'

def make_main_canvas(idx, row):
    canvas_id = f"canvas{idx}"
    button_html = ""
    if row["button_id"]:
        button_html += f'<button id="{row["button_id"]}" class="rive-btn">Trigger</button>'
        if row["input1"]:
            button_html += f' <input type="number" id="{row["button_id"]}_input" value="80" style="width:30px; margin-left: 8px;" />'
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
        src = f"riv/{row['src']}"
        state_machine = row["state_machine"] if "State Machine" in row["state_machine"] else ""
        artboard = row["artboard"] if row.get("artboard") else ""
        artboard_line = f'artboard: "{artboard}",' if artboard else ""
        state_machine_line = f' stateMachines: "{state_machine}",' if state_machine else ""
        script += f'''
const r{idx} = new rive.Rive({{
  src: "{src}",
  canvas: document.getElementById("{canvas_id}"),
  autoplay: true,{artboard_line}{state_machine_line}
  onLoad: () => {{
    r{idx}.resizeDrawingSurfaceToCanvas();
  }},
}});
'''
        if row["button_id"] and row["trigger"]:
            script += f'''
let triggerInput{idx};
r{idx}.on("load", () => {{
  const inputs = r{idx}.stateMachineInputs("{state_machine}");
  triggerInput{idx} = inputs.find(input => input.name === "{row["trigger"]}");
}});
document.getElementById("{row["button_id"]}").addEventListener("click", () => {{
  if (triggerInput{idx}) {{
    triggerInput{idx}.fire();
  }}
}});
'''
        if row["button_id"] and row["input1"]:
            script += f'''
let numberInput{idx};
let inputField{idx} = document.getElementById("{row["button_id"]}_input");
r{idx}.on("load", () => {{
  const inputs = r{idx}.stateMachineInputs("{state_machine}");
  numberInput{idx} = inputs.find(input => input.name === "{row["input1"]}");
  if (inputField{idx} && numberInput{idx}) {{
    inputField{idx}.addEventListener("input", () => {{
      let val = parseFloat(inputField{idx}.value);
      if (!isNaN(val)) numberInput{idx}.value = val;
    }});
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
    desc = f'<a href="../riv/{row["src"]}" target="_blank" style="color: white;">{row["name"]}</a><br>'
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
        if row["button_id"]:
            html += f'<button id="{row["button_id"]}" class="rive-btn">Trigger</button>'
            if row["input1"]:
                html += f' <input type="number" id="{row["button_id"]}_input" value="80" style="width:30px; margin-left: 8px;" />'
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
        if row["button_id"]:
            html += f'<button id="{row["button_id"]}_preview" class="rive-btn">Trigger</button>'
            if row["input1"]:
                html += f' <input type="number" id="{row["button_id"]}_preview_input" value="80" style="width:30px; margin-left: 8px;" />'
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
        if row["button_id"]:
            html += f'<button id="{row["button_id"]}" class="rive-btn">Trigger</button>'
            if row["input1"]:
                html += f' <input type="number" id="{row["button_id"]}_input" value="80" style="width:30px; margin-left: 8px;" />'
        html += '''
          </div>
        </div>
      </div>
    </div>
'''

    html += '''
<script>
const mainRive = new rive.Rive({
  src: "%s",
  canvas: document.getElementById("main_canvas"),
  autoplay: true,%s%s
  onLoad: () => {
    mainRive.resizeDrawingSurfaceToCanvas();
  },
});
''' % (
        main_rive,
        f' artboard: "{row["artboard"]}",' if row.get("artboard") else "",
        f' stateMachines: "{row["state_machine"]}",' if row.get("state_machine") else ""
    )

    # Main animation buttons/inputs JS
    if row["button_id"] and row["trigger"]:
        html += f'''
let triggerInputMain;
mainRive.on("load", () => {{
  const inputs = mainRive.stateMachineInputs("{row["state_machine"]}");
  triggerInputMain = inputs.find(input => input.name === "{row["trigger"]}");
}});
document.getElementById("{row["button_id"]}").addEventListener("click", () => {{
  if (triggerInputMain) {{
    triggerInputMain.fire();
  }}
}});
'''
    if row["button_id"] and row["input1"]:
        html += f'''
let numberInputMain;
let inputFieldMain = document.getElementById("{row["button_id"]}_input");
mainRive.on("load", () => {{
  const inputs = mainRive.stateMachineInputs("{row["state_machine"]}");
  numberInputMain = inputs.find(input => input.name === "{row["input1"]}");
  if (inputFieldMain && numberInputMain) {{
    inputFieldMain.addEventListener("input", () => {{
      let val = parseFloat(inputFieldMain.value);
      if (!isNaN(val)) numberInputMain.value = val;
    }});
  }}
}});
'''

    # Preview animation JS and buttons/inputs
    if preview_rive:
        html += '''
const previewRive = new rive.Rive({
  src: "%s",
  canvas: document.getElementById("preview_canvas"),
  autoplay: true,%s%s
  onLoad: () => {
    previewRive.resizeDrawingSurfaceToCanvas();
  },
});
''' % (
        preview_rive,
        f' artboard: "{row["artboard"]}",' if row.get("artboard") else "",
        f' stateMachines: "{row["state_machine"]}",' if row.get("state_machine") else ""
    )
        if row["button_id"] and row["trigger"]:
            html += f'''
let triggerInputPreview;
previewRive.on("load", () => {{
  const inputs = previewRive.stateMachineInputs("{row["state_machine"]}");
  triggerInputPreview = inputs.find(input => input.name === "{row["trigger"]}");
}});
document.getElementById("{row["button_id"]}_preview").addEventListener("click", () => {{
  if (triggerInputPreview) {{
    triggerInputPreview.fire();
  }}
}});
'''
        if row["button_id"] and row["input1"]:
            html += f'''
let numberInputPreview;
let inputFieldPreview = document.getElementById("{row["button_id"]}_preview_input");
previewRive.on("load", () => {{
  const inputs = previewRive.stateMachineInputs("{row["state_machine"]}");
  numberInputPreview = inputs.find(input => input.name === "{row["input1"]}");
  if (inputFieldPreview && numberInputPreview) {{
    inputFieldPreview.addEventListener("input", () => {{
      let val = parseFloat(inputFieldPreview.value);
      if (!isNaN(val)) numberInputPreview.value = val;
    }});
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