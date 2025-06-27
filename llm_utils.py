import openai

openai.api_base = "http://127.0.0.1:1234/v1"
openai.api_key = "not-needed"  # Not required by LM Studio

# Replace this string if you want to use the :2 version or another model
LMSTUDIO_MODEL_NAME = "qwen/qwen2.5-coder-14b"

def lmstudio_inference(prompt, max_new_tokens=512):
    try:
        response = openai.ChatCompletion.create(
            model=LMSTUDIO_MODEL_NAME,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=max_new_tokens,
            temperature=0.2,
        )
        return response.choices[0].message.content
    except Exception as e:
        return f"Error parsing response: {e}"
