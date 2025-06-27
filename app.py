import streamlit as st
from rag_utils import retrieve_context
from llm_utils import lmstudio_inference
from prompt_templates import GEN_PROMPT, CORRECT_PROMPT, GPU_PROMPT

st.set_page_config(page_title="RAG Code Tutor", layout="wide")
st.title("💻 RAG Code & Concept Tutor (GPU Hackathon)")

task_type = st.selectbox(
    "What do you want to do?",
    ["Code Generation", "Code Correction (Hints)", "GPU Optimization"],
    index=0
)

top_k = st.slider("How many context chunks to retrieve?", min_value=2, max_value=8, value=4, step=1)

if task_type == "Code Generation":
    user_task = st.text_area("Describe your ML/data science task (in detail):")
    code_input = None
elif task_type == "Code Correction (Hints)":
    code_input = st.text_area("Paste your Python code here:")
    user_task = st.text_area("What does this code do? (optional, for better context)")
else:  # GPU Optimization
    code_input = st.text_area("Paste your Python code for GPU optimization:")
    user_task = st.text_area("Describe what this code is doing. (optional)")

if st.button("Get LLM Answer"):
    with st.spinner("Retrieving context..."):
        query_text = user_task if user_task else (code_input if code_input else "")
        context, metadatas = retrieve_context(query_text, top_k=top_k)

    # Build the right prompt
    if task_type == "Code Generation":
        prompt = GEN_PROMPT.format(task=user_task, context=context)
    elif task_type == "Code Correction (Hints)":
        prompt = CORRECT_PROMPT.format(code=code_input, context=context)
    else:  # GPU Optimization
        prompt = GPU_PROMPT.format(code=code_input, context=context)

    with st.spinner("LLM generating answer (Qwen2.5-Coder-14B)..."):
        answer = lmstudio_inference(prompt)

    st.markdown("### 🔎 Retrieved Context")
    st.code(context, language="markdown")
    st.markdown("### 🤖 LLM Answer")
    st.write(answer)
    st.markdown("### 📚 Sources")
    for i, meta in enumerate(metadatas, 1):
        st.write(f"[{i}] {meta['source']} ({meta.get('type','')})")
    