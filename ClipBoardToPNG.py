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

import subprocess
import tempfile

def save_clipboard_image_mac_native(output_path):
    mac_script = """
#import <Cocoa/Cocoa.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSArray *classes = @[[NSImage class]];
        NSDictionary *options = @{};
        if ([pasteboard canReadObjectForClasses:classes options:options]) {
            NSArray *images = [pasteboard readObjectsForClasses:classes options:options];
            if ([images count] > 0) {
                NSImage *image = images[0];
                CGImageRef cgRef = [image CGImageForProposedRect:NULL context:nil hints:nil];
                NSBitmapImageRep *newRep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
                [newRep setSize:[image size]];
                NSData *pngData = [newRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if (argc > 1) {
                    [pngData writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
                    printf("Success\\n");
                    return 0;
                }
            }
        }
        printf("No image\\n");
        return 1;
    }
}
"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.m', delete=False) as f:
        f.write(mac_script)
        src_file = f.name
    
    bin_file = src_file[:-2]
    try:
        subprocess.run(["clang", "-framework", "Cocoa", "-o", bin_file, src_file], check=True, capture_output=True)
        result = subprocess.run([bin_file, output_path], capture_output=True, text=True)
        if "Success" in result.stdout:
            print(f"Image saved to {output_path}")
        else:
            print("No image found in clipboard.")
    finally:
        if os.path.exists(src_file):
            os.remove(src_file)
        if os.path.exists(bin_file):
            os.remove(bin_file)

def save_clipboard_image_to_png(output_path):
    unique_path = get_unique_filename(output_path)

    if sys.platform == "darwin":
        save_clipboard_image_mac_native(unique_path)
        return

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
    if len(sys.argv) > 1:
        output_file = sys.argv[1]
    else:
        if sys.platform == "darwin":
            output_file = os.path.expanduser("~/Downloads/clipboard_image.png")
        else:
            output_file = r"c:/temp/clipboard_image.png"
    save_clipboard_image_to_png(output_file)