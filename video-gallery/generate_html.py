import csv

csv_path = "videos.csv"
output_html = "index.html"

html_head = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <title>Rive Animation Gallery</title>
    <style>
        body { background: #111; color: #eee; font-family: sans-serif; }
        .animation-wrapper { display: flex; flex-wrap: wrap; gap: 30px; max-width: 900px; margin: 0 auto; }
        .animation-container { display: flex; flex-direction: column; margin-bottom: 20px; }
        .description { color: #888; font-size: 0.9rem; margin-top: 8px; line-height: 1.4; }
        canvas { border: 1px solid #292929; }
    </style>
    <script src="https://unpkg.com/@rive-app/webgl2"></script>
</head>
<body>
    <div class="animation-wrapper">
"""

html_foot = """
    </div>
</body>
</html>
"""

def make_description(row):
    desc = f'Size: {row["size"]}<br>'
    desc += f'Animation/State Machine: {row["animation_or_state_machine"]}<br>'
    if row["trigger"]:
        desc += f'Trigger: {row["trigger"]}<br>'
    desc += f'Duration: {row["duration"]}s<br>'
    desc += f'Loop: {row["loop"]}<br>'
    desc += f'Background: {row["background"]}<br>'
    if row["button_id"]:
        desc += f'<button id="{row["button_id"]}">Trigger</button><br>'
    return desc

def make_canvas(idx, row):
    canvas_id = f"canvas{idx}"
    return f'''
      <div class="animation-container">
        <canvas id="{canvas_id}" width="{row["width"]}" height="{row["height"]}"></canvas>
        <div class="description">
          {make_description(row)}
        </div>
      </div>
    '''

def make_script(rows):
    script = "<script>\n"
    for idx, row in enumerate(rows):
        canvas_id = f"canvas{idx}"
        src = row["src"]
        state_machine = row["animation_or_state_machine"] if "State Machine" in row["animation_or_state_machine"] else ""
        script += f'''
const r{idx} = new rive.Rive({{
  src: "{src}",
  canvas: document.getElementById("{canvas_id}"),
  autoplay: true,{f' stateMachines: "{state_machine}",' if state_machine else ""}
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
    script += '''
document.querySelectorAll('canvas').forEach(canvas => {
  canvas.style.width = canvas.width + "px";
  canvas.style.height = canvas.height + "px";
});
</script>
'''
    return script

with open(csv_path, newline='', encoding='utf-8') as csvfile:
    reader = csv.DictReader(csvfile)
    rows = list(reader)

with open(output_html, "w", encoding="utf-8") as f:
    f.write(html_head)
    for idx, row in enumerate(rows):
        f.write(make_canvas(idx, row))
    f.write("</div>\n")
    f.write(make_script(rows))
    f.write(html_foot)

print(f"Generated {output_html}")