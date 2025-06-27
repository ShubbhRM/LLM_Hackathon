# 🚀 LLM Hackathon: Retrieval-Augmented Code Tutor & Optimizer

Welcome to the **LLM Hackathon Project**!  
This repository contains a Retrieval-Augmented Generation (RAG) system that combines your own code/data science documentation with a large language model (LLM) running locally—**no API key, no cloud required!**

---

## 🧑‍🎓 What Will You Learn Here?

- How Retrieval-Augmented Generation (RAG) works
- How to preprocess and index Jupyter notebooks, Markdown, PDFs, and Python files for search
- How to run LLMs like `Qwen2.5-Coder-14B` fully offline with LM Studio
- How to build a Streamlit app for interactive code generation, hints, and GPU optimization

---

## 🏗️ What Does This Project Do?

- **Code Generation:**  
  Generate clear, well-commented ML/data science code, citing your documentation.
- **Code Correction:**  
  Get hints on bugs or inefficiencies in your own code—no direct answers!
- **GPU Optimization:**  
  Receive suggestions to rewrite code for PyTorch, RAPIDS, cuDF, etc., to use the GPU.
- **Source Attribution:**  
  Every answer cites the specific file(s) and chunk(s) used for the response.

---

## 📦 Project Structure
hackathon-project/
├── app.py # Streamlit app
├── auto_chunker.py # Chunks and processes dataset/
├── build_index.py # Builds embeddings and vector DB
├── rag_utils.py # Retrieval logic
├── llm_utils.py # LM Studio/OpenAI API wrapper
├── prompt_templates.py # Prompt templates
├── requirements.txt # Python dependencies
├── README.md # You're reading it!
├── .gitignore # Ignores large/generated files
├── dataset/ # All your docs/code (organized in subfolders)
│ ├── cupy/
│ ├── cudf/
│ ├── cuml/
│ └── ...
└── chroma_db/ # (auto-generated, ignore in git)


---

## ⚙️ Setup & Commands

### 1. **Install LM Studio**

- Download from [lmstudio.ai](https://lmstudio.ai/) for your OS.
- Open LM Studio, search for, download, and **load** the model:  
  `qwen/qwen2.5-coder-14b`
- Ensure the API server is running (default: `localhost:1234`).

### 2. **Install Python Requirements**

```bash
pip install -r requirements.txt
pip install "openai<1.0.0"
```

### 3. **Add Your Data**
- Put all your .ipynb, .py, .md, and .pdf files in the dataset/ folder (subfolders like cupy, cudf, etc., are fine!).


### 4. **Chunk & Index Your Data**
```bash
python auto_chunker.py
python build_index.py
```

- This creates chunks.jsonl and builds your vector database in chroma_db/.

### 5. **Run the Streamlit Web App**

```bash
streamlit run app.py
```

- The app will open in your browser.
- Choose Code Generation, Code Hints, or GPU Optimization mode.




###  Example Prompts

**Code Generation:**
- Write a well-commented PyTorch program to classify MNIST digits using GPU if possible. Cite examples from the context if relevant.


**Code Correction:**
- Here is my cuDF code for loading a CSV and filtering by column. Can you give me hints if there are any bugs or inefficiencies?

**GPU Optimization:**
- Optimize this pandas code for RAPIDS/cuDF on GPU and explain why the changes help.



### How Does This Work?

**Retrieval:**
Finds the most relevant chunks from your own files for every question.

**Prompting:**
Uses only those chunks to build a prompt, enforcing “I don’t know” if the answer isn’t grounded in your docs.

**LLM Inference:**
Calls your local LLM via LM Studio (no cloud/API key needed).

**Display:**
Shows the result in Streamlit, with sources.

