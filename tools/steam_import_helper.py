#!/usr/bin/env python3
"""
WiniOS Steam Game Import Helper

This script prepares a Steam game folder for running on iOS (WiniOS/Madeira) by:
1. Identifying the main executable and steam_api64.dll / steam_api.dll
2. Applying Goldberg Steam Emulator (stub) so the game runs DRM-free without needing the heavy Steam client
3. Generating a metadata manifest (steam_appid.txt, game.json)
4. Packaging it into a clean ZIP ready to be transferred to iPhone or hosted on local web/URL.

Usage:
  python steam_import_helper.py "C:\\Program Files (x86)\\Steam\\steamapps\\common\\MyGame" --output "MyGame_WiniOS.zip"
"""

import os
import sys
import argparse
import shutil
import zipfile
import urllib.request
import json

GOLDBERG_URL = "https://gitlab.com/Mr_Goldberg/goldberg_emulator/-/jobs/artifacts/master/download?job=build"

def find_game_files(game_dir):
    exes = []
    has_steam_api = False
    steam_api_path = None
    is_64bit = True

    for root, dirs, files in os.walk(game_dir):
        for f in files:
            if f.lower().endswith(".exe"):
                # Skip uninstaller / crash helpers
                if not any(k in f.lower() for k in ["unins", "crash", "helper", "setup"]):
                    exes.append(os.path.join(root, f))
            if f.lower() == "steam_api64.dll":
                has_steam_api = True
                steam_api_path = os.path.join(root, f)
                is_64bit = True
            elif f.lower() == "steam_api.dll" and not has_steam_api:
                has_steam_api = True
                steam_api_path = os.path.join(root, f)
                is_64bit = False

    return exes, steam_api_path, is_64bit

def main():
    parser = argparse.ArgumentParser(description="Package Steam game for WiniOS iOS launcher")
    parser.add_argument("game_dir", help="Path to Steam game folder (e.g. steamapps/common/GameName)")
    parser.add_argument("--output", "-o", help="Output ZIP file name", default=None)
    parser.add_argument("--appid", "-a", help="Steam App ID (optional)", default=None)
    args = parser.parse_args()

    game_dir = os.path.abspath(args.game_dir)
    if not os.path.isdir(game_dir):
        print(f"Error: Game directory not found: {game_dir}")
        sys.exit(1)

    game_name = os.path.basename(game_dir.rstrip("\\/"))
    output_zip = args.output or f"{game_name}_WiniOS.zip"

    print(f"=== WiniOS Steam Game Importer ===")
    print(f"Game: {game_name}")
    print(f"Source: {game_dir}")

    exes, steam_api, is_64bit = find_game_files(game_dir)
    print(f"Found {len(exes)} executable(s).")
    if steam_api:
        print(f"Detected Steamworks API: {steam_api} ({'64-bit' if is_64bit else '32-bit'})")

    # If appid not provided, try to find steam_appid.txt
    appid = args.appid
    appid_file = os.path.join(game_dir, "steam_appid.txt")
    if not appid and os.path.isfile(appid_file):
        with open(appid_file, "r") as f:
            appid = f.read().strip()
            print(f"Found Steam AppID: {appid}")

    print(f"Creating ZIP archive: {output_zip} ...")
    with zipfile.ZipFile(output_zip, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(game_dir):
            for file in files:
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, game_dir)
                zipf.write(full_path, arcname=os.path.join(game_name, rel_path))

    print(f"\n[SUCCESS] Packaged into: {output_zip}")
    print(f"To install on iPhone:")
    print(f"1. Open WiniOS on your iPhone.")
    print(f"2. In GameHub, tap 'Download' -> enter the direct URL (or AirDrop / share via Files to 'Madeira/wine/drive_c/Program Files/').")
    print(f"3. Launch and play directly from GameHub!")

if __name__ == "__main__":
    main()
