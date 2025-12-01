import csv, os

script_dir = os.path.dirname(os.path.abspath(__file__))
csv_path = os.path.join(script_dir, "videos.csv")

with open(csv_path, newline='', encoding='utf-8') as csvfile:
    reader = csv.DictReader(csvfile, restval="")
    for row in reader:
        if row["src"] == "sleeplake_v3.riv":
            print("input1:", repr(row["input1"]))
            print("input2:", repr(row["input2"]))
            print("input3:", repr(row["input3"]))
            print("input4:", repr(row["input4"]))
            print("input5:", repr(row["input5"]))