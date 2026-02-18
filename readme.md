```
██████╗  █████╗  ██████╗      ██████╗ ██████╗ ██████╗ ███████╗
██╔══██╗██╔══██╗██╔════╝     ██╔════╝██╔═══██╗██╔══██╗██╔════╝
██████╔╝███████║██║  ███╗    ██║     ██║   ██║██║  ██║█████╗
██╔══██╗██╔══██║██║   ██║    ██║     ██║   ██║██║  ██║██╔══╝
██║  ██║██║  ██║╚██████╔╝    ╚██████╗╚██████╔╝██████╔╝███████╗
╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝      ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝
               LOCAL RAG CODE TUTOR · GPU-FIRST
```

[![Python](https://img.shields.io/badge/Python-3.10+-76b900?style=flat-square&logo=python&logoColor=white)](https://python.org)
[![LM Studio](https://img.shields.io/badge/LM_Studio-Qwen2.5--Coder--14B-76b900?style=flat-square)](https://lmstudio.ai)
[![ChromaDB](https://img.shields.io/badge/ChromaDB-Vector_DB-76b900?style=flat-square)](https://trychroma.com)
[![RAPIDS](https://img.shields.io/badge/RAPIDS-cuDF-76b900?style=flat-square&logo=nvidia&logoColor=white)](https://rapids.ai)
[![Streamlit](https://img.shields.io/badge/Streamlit-UI-76b900?style=flat-square&logo=streamlit&logoColor=white)](https://streamlit.io)
[![Offline](https://img.shields.io/badge/Cloud_Dependency-0%25-76b900?style=flat-square)](.)

---

## $ cat about.txt

A fully **offline** Retrieval-Augmented Generation system that acts as your personal GPU/ML code tutor. The entire [RAPIDS cuDF](https://github.com/rapidsai/cudf) repository (8,528 files) is indexed into ChromaDB as a vector knowledge base. Questions are answered by **Qwen2.5-Coder-14B** running locally via LM Studio — zero cloud dependency, zero API keys.

---

## $ ls features/

| Feature | Detail |
|---|---|
| 🧠 **Model** | Qwen2.5-Coder-14B — SOTA local code LLM |
| 🗄️ **Vector DB** | ChromaDB with all-MiniLM-L6-v2 embeddings (384-dim) |
| 📚 **Knowledge Base** | RAPIDS cuDF full source — 8,528 files |
| ⚡ **Retrieval** | Top-K cosine similarity, configurable 2–8 chunks |
| 🎛️ **UI** | Streamlit with mode selector + source citations |
| 🔒 **Privacy** | 100% local — your code never leaves your machine |

---

## $ ls modes/

### ⚡ Code Generation
Generates well-commented, GPU-accelerated ML code. Prefers `cudf` over `pandas`, PyTorch `.cuda()` over CPU ops.

### 🔍 Bug Hints
Identifies bugs, inefficiencies, and CPU↔GPU data copy anti-patterns. Returns hints — not solutions — so you learn.

### 🚀 GPU Optimisation
Maps your CPU code to GPU equivalents. Rewrites `pandas` → `cudf`, `numpy` → `cupy`, explains warp-level speedups.

---

## $ cat architecture.md

```
User Query
    │
    ▼
[Streamlit UI: app.py]          ← mode select + chunk-count slider
    │
    ▼
[Embed: rag_utils.py]           ← all-MiniLM-L6-v2, 384-dim, L2-norm
    │
    ▼
[ChromaDB cosine search]        ← top-K chunks from 8,528 cuDF files
    │
    ▼
[Prompt Builder: prompt_templates.py]  ← inject context into task template
    │
    ▼
[LLM: llm_utils.py]            ← Qwen2.5-Coder-14B @ localhost:1234
    │
    ▼
[Answer + cited sources]
```

---

## $ cat chunking_rules.md

| File type | Strategy |
|---|---|
| `.ipynb` | One chunk per cell (tagged: `code` / `markdown`) |
| `.py` | Split on `def ` / `class ` boundaries (tagged: `function` / `class` / `top-level`) |
| `.md` | Split on blank lines or `#` headings (tagged: `markdown`) |
| `.pdf` | Per-page extraction + blank-line split (tagged: `pdf`) |

---

## $ ls project/

```
LLM_Hackathon/
├── app.py               ← Streamlit UI (mode selector, chunk-count slider)
├── auto_chunker.py      ← Multi-format document ingestion pipeline
├── build_index.py       ← Embedding + ChromaDB indexing (batch=128)
├── rag_utils.py         ← Retrieval module (used by app.py)
├── rag_query.py         ← Standalone CLI query/test tool
├── llm_utils.py         ← LM Studio OpenAI-compat wrapper (Qwen2.5-Coder-14B)
├── prompt_templates.py  ← Three task-specific prompt templates
├── requirements.txt
├── dataset/
│   └── cudf/            ← RAPIDS cuDF source tree (8,528 files — knowledge base)
├── chunks.jsonl          ← [generated] chunked documents
└── chroma_db/            ← [generated] persistent vector store
```

---

## $ bash setup.sh

```bash
# 1. Clone & install
git clone https://github.com/ShubbhRM/LLM_Hackathon.git
cd LLM_Hackathon
pip install streamlit transformers torch requests accelerate
pip install chromadb sentence-transformers "openai<1.0.0" nbformat PyPDF2

# 2. Build vector index (one-time · ~5–10 min)
python auto_chunker.py    # produces chunks.jsonl
python build_index.py     # produces chroma_db/

# 3. Start LM Studio → load Qwen2.5-Coder-14B → enable local server (port 1234)

# 4. Launch
streamlit run app.py
# → opens at http://localhost:8501
```

---

## $ cat roadmap.md

- [x] Multi-format auto-chunker (.ipynb / .py / .md / .pdf)
- [x] ChromaDB vector indexing with L2-normalised embeddings
- [x] Three specialised LLM prompt modes
- [x] Streamlit UI with configurable chunk-count slider
- [x] Source citation display in UI
- [ ] Streaming LLM responses in UI
- [ ] BM25 hybrid retrieval (sparse + dense)
- [ ] Re-ranker (cross-encoder) pass before LLM
- [ ] Multiple knowledge bases switchable from UI
- [ ] Expand dataset to full RAPIDS ecosystem (cuML, cuGraph)

---

## $ cat tech_stack.md

| Component | Technology |
|---|---|
| LLM | Qwen2.5-Coder-14B (via LM Studio) |
| Vector DB | ChromaDB (persistent) |
| Embeddings | all-MiniLM-L6-v2 (SentenceTransformers) |
| Knowledge Base | RAPIDS cuDF full source (8,528 files) |
| UI | Streamlit |
| ML Framework | PyTorch |
| LLM API Protocol | OpenAI-compat (openai<1.0.0) |

---

*Built for hackathon · fully offline · GPU-first · no cloud*
