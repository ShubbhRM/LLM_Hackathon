# 🚀 RAG-Powered Code Tutor (with LM Studio & Streamlit)

A **Retrieval-Augmented Generation (RAG)** system for local code tutoring, error hinting, and GPU optimization—grounded in your custom documentation, running entirely **offline** with [LM Studio](https://lmstudio.ai/) and a powerful open-source LLM (`Qwen2.5-Coder-14B`).

---

## 🏗️ Architecture Overview

**1. User Interface (Streamlit Web App):**
- User selects a mode: Generate Code, Code Hints, or GPU Optimization.
- User provides a task description or code.

**2. Document Processing & Storage:**
- All your docs, code, and PDFs are preprocessed and **chunked** into manageable pieces.
- Chunks are embedded (converted into vectors) and stored in a **Chroma Vector Database**.

**3. Retrieval & Prompt Assembly:**
- For every query, the most relevant chunks are retrieved from the vector DB (using semantic similarity).
- These chunks are inserted (with citations) into one of three carefully designed prompt templates.

**4. Local LLM Inference (via LM Studio):**
- The prompt (with context) is sent to **LM Studio** over the OpenAI-compatible API (`localhost:1234/v1/chat/completions`).
- **Qwen2.5-Coder-14B** processes the prompt and returns an answer, which is shown to the user.

---

### 📊 Architecture Diagram

```mermaid
flowchart TD
    A[User (Browser)]
    B[Streamlit App]
    C[Prompt Templates]
    D[Chroma Vector DB]
    E[LM Studio API (localhost)]
    F[Qwen2.5-Coder-14B Model]
    G[Local Dataset (.py/.ipynb/.md/.pdf)]
    H[auto_chunker.py & build_index.py]
    
    A --> B
    B --> D
    D --> B
    B --> C
    B --> E
    C --> B
    E --> F
    F --> E
    E --> B
    B --> A
    G --> H
    H --> D


📝 Step-by-Step Guide
1. Install Prerequisites
Download LM Studio and install for your OS.

Python 3.9–3.11 recommended.

2. Prepare Python Environment
bash
Copy
Edit
pip install -r requirements.txt
# If you see errors about 'openai.ChatCompletion', do:
pip install "openai<1.0.0"
Example requirements.txt:

text
Copy
Edit
streamlit
openai==0.28.1
chromadb
sentence-transformers
pdfplumber
PyMuPDF
tqdm
3. Gather and Chunk Your Data
Place all .ipynb, .py, .md, and .pdf files in a folder called dataset/.

bash
Copy
Edit
python auto_chunker.py
This creates chunks.jsonl with all split chunks.

4. Build the Vector Index
bash
Copy
Edit
python build_index.py
This creates your Chroma vector DB.

5. Load Model in LM Studio
Open LM Studio.

Download and load qwen/qwen2.5-coder-14b.

Make sure the API Server is running (localhost:1234).

6. Start the App
bash
Copy
Edit
streamlit run app.py
Interact with your local code tutor!

🎛️ How the App Works
User input:

Choose between Generate Code, Get Hints, or GPU Optimize.

Enter task description or code.

Context Retrieval:

Top-k most relevant document chunks are retrieved using semantic search from the Chroma vector DB.

These chunks (with citations) are passed into the prompt template.

Prompt Formatting:

Templates enforce that the model only uses context; otherwise, it says “I don’t know.”

LLM Answer:

Prompt is sent to LM Studio over the local OpenAI-compatible API.

Answer is returned and displayed with source citations.

💡 Prompt Templates (Key Modes)
1. Code Generation

text
Copy
Edit
You are an expert Python tutor and ML engineer.

Context:
{context_chunks}

Task:
Generate well-commented Python code for the following ML or data science task:
"{task}"

- Use PyTorch or RAPIDS where possible.
- Add clear, brief comments.
- If you use examples or code patterns from the context, cite their sources in brackets, e.g., [1], [2].
- If the answer is not in the context, reply "I don't know."
2. Code Correction (Hints)

text
Copy
Edit
You are an expert Python tutor and ML engineer.

Context:
{context_chunks}

A student submitted the following Python code:
{code}

Analyze this code and, using only the context above:
- If there are bugs, logical errors, or inefficiencies, give **only hints** (not full solutions).
- Explain why each hint matters for data science or ML.
- If relevant, cite context sources in brackets, e.g., [1], [2].
- If the context is insufficient, reply "I don't know."
3. GPU Optimization

text
Copy
Edit
You are an expert in GPU optimization for Python ML/data science workflows.

Context:
{context_chunks}

Given the following Python code:
{code}

- Suggest modifications to maximize GPU usage (e.g., PyTorch `.cuda()`, RAPIDS/cuDF, cuML, etc.) using only the context above.
- Explain how your changes will improve time or memory complexity.
- Output the optimized code and a short explanation.
- Cite context sources in brackets, e.g., [1], [2].
- If the context is insufficient, reply "I don't know."
🛠️ File-by-File Breakdown
File	Purpose
auto_chunker.py	Splits all docs/code into manageable text/code chunks, supports .ipynb, .py, .md, .pdf
build_index.py	Embeds all chunks and stores in ChromaDB for semantic retrieval
rag_utils.py	Retrieves top-k relevant chunks for user query, with citations
llm_utils.py	Connects to LM Studio via OpenAI API (localhost:1234/v1/chat/completions)
prompt_templates.py	Contains all prompt templates for code gen, hints, GPU optimization
app.py	Streamlit app UI for hackathon judges/demo
chunks.jsonl	Your preprocessed data after chunking
requirements.txt	All required Python packages
README.md	This file!