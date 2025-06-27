import chromadb
from sentence_transformers import SentenceTransformer

EMBED_MODEL = "all-MiniLM-L6-v2"
embedder = SentenceTransformer(EMBED_MODEL)
client = chromadb.PersistentClient(path="chroma_db")
collection = client.get_collection("code_rag")

def retrieve_context(query, top_k=4):
    q_emb = embedder.encode([query], normalize_embeddings=True).tolist()
    results = collection.query(
        query_embeddings=q_emb,
        n_results=top_k
    )
    docs = results['documents'][0]
    metadatas = results['metadatas'][0]
    context_chunks = []
    for i, (doc, meta) in enumerate(zip(docs, metadatas), 1):
        src = meta['source']
        typ = meta.get('type', 'unknown')
        context_chunks.append(f"[{i}] ({typ}) Source: {src}\n{doc}\n")
    return "\n".join(context_chunks), metadatas
