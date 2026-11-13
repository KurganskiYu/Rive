from pathlib import Path
import shutil

from catalog_core import load_csv_rows


ROOT = Path(__file__).parent
CSV_FILE = ROOT / "_anim_list.csv"
RIV_DIR = ROOT / "riv"
OLD_DIR = ROOT / "riv_old"
PROJECT_DIR = Path("/Users/yuri/Library/CloudStorage/Dropbox/Settings/Rive_iOs/RiveTestApp/RiveTestApp")


def active_sources(csv_file):
	return {row["src"] for row in load_csv_rows(csv_file) if row["src"]}


def main():
	active_names = active_sources(CSV_FILE)
	OLD_DIR.mkdir(exist_ok=True)

	for riv_file in RIV_DIR.glob("*.riv"):
		active_name = riv_file.stem.removesuffix("_preview")
		if active_name not in active_names:
			shutil.move(str(riv_file), OLD_DIR / riv_file.name)

	shutil.copy2(CSV_FILE, PROJECT_DIR / CSV_FILE.name)

	project_riv_dir = PROJECT_DIR / "riv"
	if project_riv_dir.exists():
		shutil.rmtree(project_riv_dir)
	shutil.copytree(RIV_DIR, project_riv_dir)
	print("Sync completed successfully.")


if __name__ == "__main__":
	main()
