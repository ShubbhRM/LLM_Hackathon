import json
import chromadb
from sentence_transformers import SentenceTransformer

# Settings
EMBED_MODEL = "all-MiniLM-L6-v2"    # Same as before!
TOP_K = 4                               # Number of chunks to retrieve per query

# Load embedding model
embedder = SentenceTransformer(EMBED_MODEL)

# Connect to ChromaDB
client = chromadb.PersistentClient(path="chroma_db")
collection = client.get_collection("code_rag")

def retrieve_context(query, top_k=TOP_K):
    q_emb = embedder.encode([query], normalize_embeddings=True).tolist()
    results = collection.query(
        query_embeddings=q_emb,
        n_results=top_k
    )
    docs = results['documents'][0]
    metadatas = results['metadatas'][0]
    # Assemble context with sources/citations
    context_chunks = []
    for i, (doc, meta) in enumerate(zip(docs, metadatas), 1):
        src = meta['source']
        typ = meta.get('type', 'unknown')
        context_chunks.append(f"[{i}] ({typ}) Source: {src}\n{doc}\n")
    sources = [f"[{i}] {meta['source']}" for i, meta in enumerate(metadatas, 1)]
    return "\n".join(context_chunks), "\n".join(sources)

if __name__ == "__main__":
    print("Ready to answer your queries using your RAG DB!")
    while True:
        user_query = input("\nEnter your ML/data/code question (or 'exit'): ")
        if user_query.lower() == "exit":
            break
        context, sources = retrieve_context(user_query, TOP_K)
        print("\n--- Retrieved Context Chunks ---")
        print(context)
        print("\n--- Sources ---")
        print(sources)
        print("\n--- Example: Send this to your LLM as context! ---")
