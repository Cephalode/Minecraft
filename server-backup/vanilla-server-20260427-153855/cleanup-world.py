#!/usr/bin/env python3
"""
Minecraft world cleanup script:
1. Clear all player inventories and ender chests
2. Clear container contents (chests, barrels, shulker boxes) in a specified region
"""

import gzip
import struct
import io
import os
import zlib
import sys
from pathlib import Path
from nbtlib import File, Compound, List

WORLD_DIR = Path.home() / "devel/minecraft/minecraft-server/world"
PLAYERDATA_DIR = WORLD_DIR / "players/data"
REGION_DIR = WORLD_DIR / "dimensions/minecraft/overworld/region"

# Target region: x from -450 to 400, z from -1350 to -1000
X_MIN, X_MAX = -450, 400
Z_MIN, Z_MAX = -1350, -1000

# Container types to clear
CONTAINER_TYPES = {
    "minecraft:chest",
    "minecraft:barrel",
    "minecraft:shulker_box",
    "minecraft:white_shulker_box",
    "minecraft:orange_shulker_box",
    "minecraft:magenta_shulker_box",
    "minecraft:light_blue_shulker_box",
    "minecraft:yellow_shulker_box",
    "minecraft:lime_shulker_box",
    "minecraft:pink_shulker_box",
    "minecraft:gray_shulker_box",
    "minecraft:light_gray_shulker_box",
    "minecraft:cyan_shulker_box",
    "minecraft:purple_shulker_box",
    "minecraft:blue_shulker_box",
    "minecraft:brown_shulker_box",
    "minecraft:green_shulker_box",
    "minecraft:red_shulker_box",
    "minecraft:black_shulker_box",
}

def clear_player_data():
    """Clear inventories and ender chests for all players."""
    cleared = 0
    if not PLAYERDATA_DIR.exists():
        print(f"  No playerdata directory found at {PLAYERDATA_DIR}")
        return 0

    for dat_file in sorted(PLAYERDATA_DIR.glob("*.dat")):
        if dat_file.name.endswith("_old.gz"):
            continue
        try:
            with open(dat_file, 'rb') as f:
                raw = f.read()
            decompressed = gzip.decompress(raw)
            nbt_file = File.from_fileobj(io.BytesIO(decompressed))
            changed = False

            # Clear Inventory
            if "Inventory" in nbt_file and len(nbt_file["Inventory"]) > 0:
                inv_count = len(nbt_file["Inventory"])
                nbt_file["Inventory"] = List[Compound]()
                changed = True
                print(f"  {dat_file.name}: Cleared inventory ({inv_count} items)")

            # Clear EnderItems (ender chest)
            if "EnderItems" in nbt_file and len(nbt_file["EnderItems"]) > 0:
                ender_count = len(nbt_file["EnderItems"])
                nbt_file["EnderItems"] = List[Compound]()
                changed = True
                print(f"  {dat_file.name}: Cleared ender chest ({ender_count} items)")

            if changed:
                buf = io.BytesIO()
                nbt_file.write(buf)
                new_data = gzip.compress(buf.getvalue())
                with open(dat_file, 'wb') as f:
                    f.write(new_data)
                cleared += 1
            else:
                print(f"  {dat_file.name}: No items to clear")

        except Exception as e:
            print(f"  {dat_file.name}: ERROR - {e}")

    return cleared

def process_containers():
    """Clear container contents in the specified coordinate range from region files."""
    cleared_chests = 0
    cleared_items = 0

    region_x_min = (X_MIN >> 4) >> 5
    region_x_max = (X_MAX >> 4) >> 5
    region_z_min = (Z_MIN >> 4) >> 5
    region_z_max = (Z_MAX >> 4) >> 5

    print(f"  Checking regions r.{region_x_min}.{region_z_min}.mca to r.{region_x_max}.{region_z_max}.mca")

    for rx in range(region_x_min, region_x_max + 1):
        for rz in range(region_z_min, region_z_max + 1):
            region_file = REGION_DIR / f"r.{rx}.{rz}.mca"
            if not region_file.exists():
                continue

            print(f"  Processing {region_file.name}...")

            with open(region_file, 'rb') as f:
                raw = bytearray(f.read())

            # Parse locations table
            locations = []
            for i in range(1024):
                b = raw[i*4:(i+1)*4]
                offset = ((b[0] << 16) | (b[1] << 8) | b[2]) * 4096
                sector_count = b[3]
                locations.append((offset, sector_count))

            timestamps = bytes(raw[4096:8192])
            modified_chunks = {}
            file_modified = False

            for idx in range(1024):
                offset, sector_count = locations[idx]
                if offset == 0 and sector_count == 0:
                    continue

                cx = idx % 32
                cz = idx // 32
                global_cx = rx * 32 + cx
                global_cz = rz * 32 + cz

                # Chunk-level range check
                chunk_x_min = global_cx * 16
                chunk_x_max = chunk_x_min + 15
                chunk_z_min = global_cz * 16
                chunk_z_max = chunk_z_min + 15

                if chunk_x_max < X_MIN or chunk_x_min > X_MAX:
                    continue
                if chunk_z_max < Z_MIN or chunk_z_min > Z_MAX:
                    continue

                # Read chunk
                length = struct.unpack('>I', raw[offset:offset+4])[0]
                compression = raw[offset+4]
                compressed_data = bytes(raw[offset+5:offset+4+length])

                try:
                    if compression == 1:
                        decompressed = gzip.decompress(compressed_data)
                    elif compression == 2:
                        decompressed = zlib.decompress(compressed_data)
                    else:
                        continue
                except:
                    continue

                # Parse NBT
                try:
                    chunk_nbt = File.from_fileobj(io.BytesIO(decompressed))
                except Exception as e:
                    continue

                if "block_entities" not in chunk_nbt:
                    continue

                chunk_modified = False
                for be in chunk_nbt["block_entities"]:
                    be_type = str(be.get("id", ""))
                    if be_type not in CONTAINER_TYPES:
                        continue

                    be_x = int(be.get("x", 0))
                    be_z = int(be.get("z", 0))

                    if not (X_MIN <= be_x <= X_MAX and Z_MIN <= be_z <= Z_MAX):
                        continue

                    if "Items" in be and len(be["Items"]) > 0:
                        item_count = len(be["Items"])
                        be["Items"] = List[Compound]()
                        cleared_chests += 1
                        cleared_items += item_count
                        print(f"    Cleared {be_type} at ({be_x}, ~, {be_z}): {item_count} items")
                        chunk_modified = True

                if chunk_modified:
                    buf = io.BytesIO()
                    chunk_nbt.write(buf)
                    new_decompressed = buf.getvalue()
                    new_compressed = zlib.compress(new_decompressed)
                    modified_chunks[idx] = new_compressed
                    file_modified = True

            if file_modified:
                print(f"  Writing modified {region_file.name}...")
                new_data = bytearray()
                loc_table = bytearray(4096)
                ts_table = bytearray(timestamps)
                new_data.extend(b'\x00' * 8192)  # placeholder header

                for idx in range(1024):
                    old_offset, old_sector_count = locations[idx]

                    if idx in modified_chunks:
                        compressed = modified_chunks[idx]
                    elif old_offset > 0 and old_sector_count > 0:
                        length = struct.unpack('>I', raw[old_offset:old_offset+4])[0]
                        compressed = bytes(raw[old_offset+5:old_offset+4+length])
                    else:
                        continue

                    total_size = 4 + 1 + len(compressed)
                    padded_size = ((total_size + 4095) // 4096) * 4096

                    chunk_offset = len(new_data)
                    sector_count = padded_size // 4096

                    new_data.extend(struct.pack('>I', len(compressed) + 1))
                    new_data.append(0x02)
                    new_data.extend(compressed)
                    new_data.extend(b'\x00' * (padded_size - total_size))

                    offset_sectors = chunk_offset // 4096
                    loc_table[idx*4] = (offset_sectors >> 16) & 0xFF
                    loc_table[idx*4+1] = (offset_sectors >> 8) & 0xFF
                    loc_table[idx*4+2] = offset_sectors & 0xFF
                    loc_table[idx*4+3] = sector_count

                new_data[0:4096] = loc_table
                new_data[4096:8192] = ts_table

                with open(region_file, 'wb') as f:
                    f.write(new_data)

    print(f"  Total containers cleared: {cleared_chests}, items removed: {cleared_items}")
    return cleared_chests

if __name__ == "__main__":
    print("=" * 60)
    print("Minecraft World Cleanup")
    print("=" * 60)
    print(f"\nContainer region: x=[{X_MIN}, {X_MAX}], z=[{Z_MIN}, {Z_MAX}]")

    print("\n--- Step 1: Clearing player inventories and ender chests ---")
    players_cleared = clear_player_data()
    print(f"  Total players modified: {players_cleared}")

    print(f"\n--- Step 2: Clearing containers in region ---")
    chests_cleared = process_containers()

    print(f"\n{'=' * 60}")
    print(f"DONE! Players modified: {players_cleared}, Containers cleared: {chests_cleared}")
    print("=" * 60)
