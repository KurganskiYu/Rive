from pathlib import Path
import csv
import re
import shutil


ROOT = Path(__file__).parent
CSV_FILE = ROOT / "_videos.csv"
SELECTED_CSV_PATTERN = re.compile(r"_videos_selected[1-9]\d*\.csv")
RIV_DIR = ROOT / "riv"
OLD_DIR = ROOT / "riv_old"
PROJECT_DIR = Path("/Users/yuri/Library/CloudStorage/Dropbox/Settings/Rive_iOs/RiveTestApp/RiveTestApp")


catalog_files = [
	CSV_FILE,
	*sorted(
		path
		for path in ROOT.iterdir()
		if SELECTED_CSV_PATTERN.fullmatch(path.name)
	),
]
active_names = set()

for catalog_file in catalog_files:
	with catalog_file.open(newline="") as file:
		active_names.update(
			row["src"]
			for row in csv.DictReader(file)
			if row.get("src")
		)

OLD_DIR.mkdir(exist_ok=True)

for riv_file in RIV_DIR.glob("*.riv"):
	active_name = riv_file.stem.removesuffix("_preview")
	if active_name not in active_names:
		shutil.move(str(riv_file), OLD_DIR / riv_file.name)

shutil.copy2(CSV_FILE, PROJECT_DIR / CSV_FILE.name)

PROJECT_RIV_DIR = PROJECT_DIR / "riv"
if PROJECT_RIV_DIR.exists():
	shutil.rmtree(PROJECT_RIV_DIR)

shutil.copytree(RIV_DIR, PROJECT_RIV_DIR)
