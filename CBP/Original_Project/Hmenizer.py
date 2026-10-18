import os
from openai import OpenAI

# 1. Set your OpenAI API key
os.environ["OPENAI_API_KEY"] = "your-api-key-here" 
client = OpenAI()

def humanize_text_file(input_filename, output_filename):
    """
    Reads text from an input file, asks an LLM to humanize it, 
    and writes the result to an output file.
    """
    try:
        # 2. Read the original AI-generated text
        with open(input_filename, 'r', encoding='utf-8') as file:
            original_text = file.read()
            
        print(f"Reading from {input_filename}...")

        # 3. Formulate the prompt for the AI
        prompt = f"""
        Please rewrite the following research text to sound like it was written by a human researcher, not an AI. 
        
        Guidelines:
        - Vary the sentence length and structure (some short, some long).
        - Remove typical AI buzzwords (e.g., "delve into," "testament to," "multifaceted," "tapestry").
        - Use a natural, conversational, yet professional academic tone.
        - Introduce slight imperfections or transitional phrases a human would use.
        - Ensure the core facts and research findings remain exactly the same.

        Text to rewrite:
        {original_text}
        """

        print("Sending to API for humanization...")
        
        # 4. Call the OpenAI API
        response = client.chat.completions.create(
            model="gpt-4o", 
            messages=[
                {"role": "system", "content": "You are an expert editor who specializes in making AI-generated academic text sound completely natural and human-written."},
                {"role": "user", "content": prompt}
            ],
            temperature=0.7 
        )

        humanized_text = response.choices[0].message.content

        # 5. Save the humanized text to the new file
        with open(output_filename, 'w', encoding='utf-8') as file:
            file.write(humanized_text)
            
        print(f"Success! Humanized text saved to {output_filename}")

    except FileNotFoundError:
        print(f"Error: The file {input_filename} was not found. Please make sure it is in the same folder as this script.")
    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    # Updated to your specific file names
    input_file = "text_A.txt"   
    output_file = "text_H.txt" 
    
    humanize_text_file(input_file, output_file)