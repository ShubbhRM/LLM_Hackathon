import os
import json
import re

def chunk_ipynb(file_path):
    import nbformat
    chunks = []
    nb = nbformat.read(file_path, as_version=4)
    for cell in nb.cells:
        cell_type = cell.cell_type
        chunks.append({
            'text': cell.source,
            'source': file_path,
            'type': cell_type
        })
    return chunks

def chunk_py(file_path):
    chunks = []
    with open(file_path, encoding='utf-8') as f:
        content = f.read()
    pattern = r'(?=^def |^class )'
    splits = re.split(pattern, content, flags=re.MULTILINE)
    for block in splits:
        block = block.strip()
        if not block:
            continue
        if block.startswith('def '):
            typ = 'function'
        elif block.startswith('class '):
            typ = 'class'
        else:
            typ = 'top-level'
        chunks.append({
            'text': block,
            'source': file_path,
            'type': typ
        })
    return chunks

def chunk_md(file_path):
    chunks = []
    with open(file_path, encoding='utf-8') as f:
        content = f.read()
    splits = re.split(r'\n\s*\n|^#', content, flags=re.MULTILINE)
    for block in splits:
        block = block.strip()
        if block:
            chunks.append({
                'text': block,
                'source': file_path,
                'type': 'markdown'
            })
    return chunks

def chunk_pdf(file_path):
    from PyPDF2 import PdfReader
    chunks = []
    try:
        reader = PdfReader(file_path)
        text = ""
        for page in reader.pages:
            page_text = page.extract_text()
            if page_text:
                text += page_text + "\n"
        paragraphs = re.split(r'\n\s*\n', text)
        for para in paragraphs:
            para = para.strip()
            if len(para) > 30:
                chunks.append({
                    'text': para,
                    'source': file_path,
                    'type': 'pdf'
                })
    except Exception as e:
        print(f"Error reading {file_path}: {e}")
    return chunks

def auto_chunk_folder(root_folder):
    all_chunks = []
    for dirpath, _, filenames in os.walk(root_folder):
        for filename in filenames:
            file_path = os.path.join(dirpath, filename)
            if filename.endswith('.ipynb'):
                try:
                    all_chunks.extend(chunk_ipynb(file_path))
                except Exception as e:
                    print(f"Error reading {file_path}: {e}")
            elif filename.endswith('.py'):
                try:
                    all_chunks.extend(chunk_py(file_path))
                except Exception as e:
                    print(f"Error reading {file_path}: {e}")
            elif filename.endswith('.md'):
                try:
                    all_chunks.extend(chunk_md(file_path))
                except Exception as e:
                    print(f"Error reading {file_path}: {e}")
            elif filename.endswith('.pdf'):
                try:
                    all_chunks.extend(chunk_pdf(file_path))
                except Exception as e:
                    print(f"Error reading {file_path}: {e}")
    return all_chunks

if __name__ == "__main__":
    print("Supported file types: .ipynb, .py, .md, .pdf")
    root_folder = input("Enter the path to your dataset folder: ")
    chunks = auto_chunk_folder(root_folder)
    print(f"Total chunks: {len(chunks)}")
    with open("chunks.jsonl", "w", encoding="utf-8") as out:
        for chunk in chunks:
            out.write(json.dumps(chunk, ensure_ascii=False) + "\n")
    print("All chunks saved to chunks.jsonl")
