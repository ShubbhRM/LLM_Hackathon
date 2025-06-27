from llm_utils import MODEL_OPTIONS, hf_inference

hf_token = input("Enter your HuggingFace API Token: ")
prompt = "Write a PyTorch CNN for CIFAR-10 image classification."

for name, model_id in MODEL_OPTIONS.items():
    print(f"--- Results from {name} ---")
    output = hf_inference(prompt, model_id, hf_token)
    print(output)
    print()
