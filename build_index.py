import json
import chromadb
from sentence_transformers import SentenceTransformer
from tqdm import tqdm

EMBED_MODEL = "all-MiniLM-L6-v2"
embedder = SentenceTransformer(EMBED_MODEL)

chunks = []
with open("chunks.jsonl", encoding="utf-8") as f:
    for line in f:
        chunks.append(json.loads(line))

print(f"Loaded {len(chunks)} chunks.")

client = chromadb.PersistentClient(path="chroma_db")
collection = client.get_or_create_collection("code_rag")

batch_size = 128
for i in tqdm(range(0, len(chunks), batch_size)):
    batch = chunks[i:i+batch_size]
    docs = [chunk["text"] for chunk in batch]
    metadatas = [{"source": chunk["source"], "type": chunk["type"]} for chunk in batch]
    ids = [f"chunk_{i+j}" for j in range(len(batch))]
    embeddings = embedder.encode(docs, normalize_embeddings=True).tolist()
    collection.add(
        documents=docs,
        embeddings=embeddings,
        metadatas=metadatas,
        ids=ids
    )

print("Embedding & indexing complete! Vector DB is ready to use.")
