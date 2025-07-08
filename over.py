import os

OUTPUT_FILE = "all_files_dump.txt"
SEPARATOR = "======"

def dump_files(root_dir, output_file):
    with open(output_file, "w", encoding="utf-8") as out:
        for dirpath, _, filenames in os.walk(root_dir):
            if ".git" in dirpath or "flux-system" in dirpath:
                continue
            for filename in filenames:
                if "all_files" in filename or "over.py" in filename:
                    continue
                rel_path = os.path.relpath(os.path.join(dirpath, filename), root_dir)
                # if rel_path.startswith("apps"):
                #     continue
                try:
                    with open(os.path.join(dirpath, filename), "r", encoding="utf-8") as f:
                        content = f.read()
                except Exception as e:
                    print(f"Cannot read {rel_path}: {e}")
                    continue

                out.write(f"file {rel_path}\n")
                out.write(f"{SEPARATOR}\n")
                out.write(content)
                out.write(f"\n{SEPARATOR}\n")

if __name__ == "__main__":
    dump_files(".", OUTPUT_FILE)
