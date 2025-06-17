from PIL import ImageGrab
import sys
import os

def get_unique_filename(filepath):
    base, ext = os.path.splitext(filepath)
    counter = 1
    unique_filepath = filepath
    while os.path.exists(unique_filepath):
        unique_filepath = f"{base}_{counter}{ext}"
        counter += 1
    return unique_filepath

def save_clipboard_image_to_png(output_path):
    # Grab image from clipboard
    img = ImageGrab.grabclipboard()
    if img is None:
        print("No image found in clipboard.")
        return

    # Convert to RGBA if not already
    if img.mode != 'RGBA':
        img = img.convert('RGBA')

    unique_path = get_unique_filename(output_path)
    img.save(unique_path, 'PNG')
    print(f"Image saved to {unique_path}")

if __name__ == "__main__":
    output_file = sys.argv[1] if len(sys.argv) > 1 else r"c:/temp/clipboard_image.png"
    save_clipboard_image_to_png(output_file)