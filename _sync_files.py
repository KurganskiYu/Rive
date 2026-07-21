from pathlib import Path
import csv
import shutil


ROOT = Path(__file__).parent
CSV_FILE = ROOT / "_videos.csv"
RIV_DIR = ROOT / "riv"
OLD_DIR = ROOT / "riv_old"
PROJECT_DIR = Path("/Users/yuri/Library/CloudStorage/Dropbox/Settings/Rive_iOs/RiveTestApp/RiveTestApp")


with CSV_FILE.open(newline="") as file:
	active_names = {
		row["src"]
		for row in csv.DictReader(file)
		if row.get("src")
	}

OLD_DIR.mkdir(exist_ok=True)

for riv_file in RIV_DIR.glob("*.riv"):
	if riv_file.stem not in active_names:
		shutil.move(str(riv_file), OLD_DIR / riv_file.name)

shutil.copy2(CSV_FILE, PROJECT_DIR / CSV_FILE.name)

PROJECT_RIV_DIR = PROJECT_DIR / "riv"
if PROJECT_RIV_DIR.exists():
	shutil.rmtree(PROJECT_RIV_DIR)

shutil.copytree(RIV_DIR, PROJECT_RIV_DIR)
