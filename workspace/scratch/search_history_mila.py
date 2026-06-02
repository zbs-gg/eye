import os
import re

CLEAN_DIR = "/Users/nikshilov/OpenClawWorkspace/chat-history-clean"
out_file = "/Users/nikshilov/.gemini/antigravity/scratch/search_results.txt"

# Let's search for "Мила" (not "Людмила" unless it's "Мила") and "Mila"
mila_pattern = re.compile(r"\bМила\b|\bMila\b", re.IGNORECASE)
ludmila_pattern = re.compile(r"Людмил", re.IGNORECASE)

results = []

for file in sorted(os.listdir(CLEAN_DIR)):
    if not file.endswith(".md"):
        continue
    filepath = os.path.join(CLEAN_DIR, file)
    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
        
    for i, line in enumerate(lines):
        if mila_pattern.search(line) and not ludmila_pattern.search(line):
            # context: 3 lines before and after
            start = max(0, i - 5)
            end = min(len(lines), i + 6)
            context = "".join(lines[start:end])
            results.append(f"=== File: {file}, Line: {i+1} ===\n{context}\n")

with open(out_file, "w", encoding="utf-8") as f:
    f.write("\n".join(results))

print(f"Done, found {len(results)} matches.")
