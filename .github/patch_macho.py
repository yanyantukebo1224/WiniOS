import sys
import glob

def patch_file(filepath):
    print(f"Checking Mach-O platform in {filepath}...")
    with open(filepath, "rb") as f:
        data = bytearray(f.read())

    pos = 0
    count = 0
    while True:
        idx = data.find(b"\x32\x00\x00\x00", pos)
        if idx == -1:
            break
        if idx + 12 <= len(data):
            cmdsize = int.from_bytes(data[idx+4:idx+8], "little")
            if 24 <= cmdsize <= 64:
                platform = int.from_bytes(data[idx+8:idx+12], "little")
                if platform == 1:  # PLATFORM_MACOS -> PLATFORM_IOS (2)
                    data[idx+8:idx+12] = (2).to_bytes(4, "little")
                    count += 1
        pos = idx + 4

    if count > 0:
        with open(filepath, "wb") as f:
            f.write(data)
        print(f"  -> Converted {count} entries from macOS to iOS in {filepath}")
    else:
        print(f"  -> No macOS entries found in {filepath}")

if __name__ == "__main__":
    targets = sys.argv[1:] if len(sys.argv) > 1 else glob.glob("app/Madeira/lib*.a")
    for t in targets:
        patch_file(t)
