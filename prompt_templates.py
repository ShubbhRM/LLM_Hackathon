GEN_PROMPT = (
    "You are an expert Python tutor. Using only the provided context, generate well-commented code for this ML/data science task: {task}.\n"
    "Use PyTorch or RAPIDS where possible. Add brief comments. Cite sources in [brackets] if appropriate.\n"
    "Context:\n{context}"
)
CORRECT_PROMPT = (
    "A student submitted this Python code:\n\n{code}\n\n"
    "Using only the context below, analyze the code. If there are bugs, logical errors, or inefficiencies, give only **hints** (not full solutions), "
    "and explain why they matter for data science or ML.\n"
    "Context:\n{context}"
)
GPU_PROMPT = (
    "Given this Python code for a data science/ML task:\n\n{code}\n\n"
    "Using only the context below, suggest modifications to maximize GPU usage (PyTorch `.cuda()`, RAPIDS/cuDF, or similar). "
    "Explain how these changes improve time or memory complexity. Output the optimized code and a brief explanation.\n"
    "Context:\n{context}"
)
