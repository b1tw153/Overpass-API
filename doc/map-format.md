# OSM Random-Access Map File Format: *.map

## Overview

The `.map` files provide **random-access lookup** from an OSM element ID to its current spatial index value. They are the complement to the `.bin` / `.bin.idx` block-backend files: where `.bin` maps *spatial tile → list of elements*, the `.map` files map *element ID → spatial tile*.

| File | Purpose | Key type | Value type |
|------|---------|----------|------------|
| `nodes.map` | Node ID → spatial index (`ll_upper`) | `Uint64` (8 B) | `Uint32_Index` (4 B) |
| `ways.map` | Way ID → spatial index | `Uint32_Index` (4 B) | `Uint31_Index` (4 B) |
| `relations.map` | Relation ID → spatial index | `Uint32_Index` (4 B) | `Uint31_Index` (4 B) |
| `nodes_attic.map` | Historical node ID → index | `Uint64` (8 B) | `Uint32_Index` (4 B) |
| `nodes_attic_undeleted.map` | Attic node, not deleted → index | `Uint64` (8 B) | `Uint32_Index` (4 B) |
| `ways_attic.map` | Historical way ID → index | `Uint32_Index` (4 B) | `Uint31_Index` (4 B) |
| `ways_attic_undeleted.map` | Attic way, not deleted → index | `Uint32_Index` (4 B) | `Uint31_Index` (4 B) |
| `relations_attic.map` | Historical relation ID → index | `Uint32_Index` (4 B) | `Uint31_Index` (4 B) |
| `relations_attic_undeleted.map` | Attic relation, not deleted → index | `Uint32_Index` (4 B) | `Uint31_Index` (4 B) |

The format is implemented by `Random_File<Key, Value>` and `Random_File_Index` in `src/template_db/random_file.h` and `src/template_db/random_file_index.h`.

**Value semantics:** The value stored for a given element ID is the same `ll_upper` / `Uint31_Index` that appears as the index key in the companion `.bin.idx` file — i.e. the quadtile that locates this element's block. A zero value (`0x00000000`) means the element has no recorded index (never written or deleted).

**Associated files for each map:**

| File | Purpose |
|------|---------|
| `{trunk}.map` | Data file — raw slots of value types |
| `{trunk}.map.idx` | Block index — maps window numbers to disk positions |
| `{trunk}.map.idx.shadow` | Shadow copy of index, used during write transactions |
| `{trunk}.map.shadow` | Free-block list, used during write transactions |

---

## File Properties

Configured in `src/overpass_api/core/settings.cc`. The constructor parameter `map_block_size_` is an internal unit; physical block size = `map_block_size_ / 8`. Map compression is always `NO_COMPRESSION` by default (`settings.cc:112`).

| Property | `nodes.map` | `ways.map` | `relations.map` | `*_undeleted.map` |
|----------|-------------|------------|-----------------|-------------------|
| Settings line | `settings.cc:125` | `settings.cc:137` | `settings.cc:149` | `settings.cc:257–317` |
| `map_block_size_` param | 256 × 1024 | 256 × 1024 | 256 × 1024 | 64 × 1024 |
| Physical block size | **32 KiB** | **32 KiB** | **32 KiB** | **8 KiB** |
| Compression factor | 8× | 8× | 8× | 8× |
| Decompressed block size | **256 KiB** | **256 KiB** | **256 KiB** | **64 KiB** |
| Default compression | `NO_COMPRESSION` | `NO_COMPRESSION` | `NO_COMPRESSION` | `NO_COMPRESSION` |
| Slot (value) size | 4 bytes | 4 bytes | 4 bytes | 4 bytes |
| Items per decompressed block | **65,536** | **65,536** | **65,536** | **16,384** |

```cpp
// src/overpass_api/core/settings.cc:51–56
uint32 get_map_block_size() const { return map_block_size/8; }      // physical block size
uint32 get_map_compression_factor() const { return 8; }
uint32 get_map_compression_method() const { return basic_settings().map_compression_method; }
// basic_settings().map_compression_method = NO_COMPRESSION (= 0)  settings.cc:112
```

---

## Addressing Model

The map file is a **slot array** addressed directly by element ID. The key space is divided into fixed-size *windows*, each covering `items_per_block` consecutive element IDs. Each window maps to one compressed-or-raw block on disk.

```
element_id  →  window_number = element_id / items_per_block
             slot_within_window = element_id % items_per_block
```

For `nodes.map` (items_per_block = 65,536):

```
node_id 0         … 65535      → window 0
node_id 65536     … 131071     → window 1
node_id N*65536   … N*65536+65535 → window N
```

**Reading a value for a given element ID:**

1. Compute `window = element_id / items_per_block` and `slot = element_id % items_per_block`.
2. Look up entry `window` in `.map.idx` (see below) to get `(pos, size)`.
3. If `pos == 0xFFFFFFFF` (npos), the value is zero (element not mapped).
4. Read `size × physical_block_size` bytes from `.map` at byte offset `pos × physical_block_size`.
5. If compressed (`ZLIB` or `LZ4`), decompress into a `decompressed_block_size` buffer.
   If `NO_COMPRESSION`, the bytes read *are* the decompressed buffer (no transformation needed).
6. Read value at byte offset `slot × slot_size` within the decompressed buffer.

**Source:** `src/template_db/random_file.h:94–110` (`get()` and `move_cache_window()`).

---

## `.map.idx` — Block Index File

Maps window numbers to disk positions. Consists of an 8-byte header followed by 8-byte entries.

**Source:** `src/template_db/random_file_index.h:294–323` (write), `src/template_db/random_file_index.h:166–210` (read).

### Header (8 bytes)

```
Offset  Size  Type    Field                    Description
------  ----  ------  -----------------------  ---------------------------------------------------
0       4     int32   file_format_version      Must equal 1007053000 (0x3C0A4A08)
4       1     uint8   block_size_log2          physical_block_bytes = 1 << this value
5       1     uint8   compression_factor_log2  compression_factor   = 1 << this value
6       2     uint16  compression_method       0=NO_COMPRESSION, 1=ZLIB, 2=LZ4
```

`FILE_FORMAT_VERSION = 1007053000` (`random_file_index.h:74`).

Written by `shift_log(block_size_)` where `shift_log(x) = floor(log2(x))` (`types.h:324`).

For `nodes.map`, `ways.map`, `relations.map` (default):
- `block_size_log2 = 15` → `physical_block_bytes = 32,768`
- `compression_factor_log2 = 3` → `compression_factor = 8`
- `compression_method = 0` (NO_COMPRESSION)

```cpp
// src/template_db/random_file_index.h:305–308
*(uint32*)index_buf.ptr = FILE_FORMAT_VERSION;       // 1007053000
*(uint8*)(index_buf.ptr + 4) = shift_log(block_size_);
*(uint8*)(index_buf.ptr + 5) = shift_log(compression_factor);
*(uint16*)(index_buf.ptr + 6) = compression_method;
```

### Index Entries (8 bytes each)

One entry per window. The total number of entries = `(file_size - 8) / 8`. There is no explicit entry-count field; readers use the file size.

```
Offset  Size  Type    Field  Description
------  ----  ------  -----  -------------------------------------------------------
0       4     uint32  pos    Start physical block number (0-based), or 0xFFFFFFFF if
                             this window has never been written
4       4     uint32  size   Number of consecutive physical blocks in this window
```

- **Byte offset** in `.map` data file: `entry.pos × physical_block_bytes`
- **Byte length** to read: `entry.size × physical_block_bytes`
- For `NO_COMPRESSION`: `entry.size = compression_factor = 8` (one window = 8 × 32 KiB = 256 KiB on disk)
- For `ZLIB` or `LZ4`: `entry.size = ceil(compressed_size / physical_block_bytes)`, typically 1

```cpp
// src/template_db/random_file_index.h:310–317
for (each entry in blocks) {
  *(uint32*)(index_buf.ptr + pos) = it->pos;   // disk block number
  pos += 4;
  *(uint32*)(index_buf.ptr + pos) = it->size;  // block count
  pos += 4;
}
```

Entry `N` (0-based, at file offset `8 + N*8`) covers element IDs in the range `[N × items_per_block, (N+1) × items_per_block − 1]`.

#### Sparse index

Windows that have never been written are **not present** as entries in the index. The `blocks` vector in memory is grown on demand; reading past the end (or an entry with `pos == npos`) returns an all-zero window. There is no entry for windows above `blocks.size()`.

---

## `.map` — Data File

A flat sequence of physical blocks. Blocks are allocated with a simple free-list allocator; the order of windows on disk is not guaranteed to match window order.

**Source:** `src/template_db/random_file.h:126–190`

### NO_COMPRESSION block layout (default)

For `NO_COMPRESSION`, each window occupies exactly `compression_factor` = 8 consecutive physical blocks (= `decompressed_block_size` = 256 KiB) on disk. The content is a flat packed array of value slots — **no header, no length prefix**:

```
Offset within window   Size         Field    Description
--------------------   ----------   -------  --------------------------------
0                      slot_size    slot[0]  Value for element_id = window*N + 0
slot_size              slot_size    slot[1]  Value for element_id = window*N + 1
2 × slot_size          slot_size    slot[2]  Value for element_id = window*N + 2
...                    ...          ...      ...
(items_per_block-1)    slot_size    slot[M]  Value for element_id = window*N + M-1
  × slot_size
```

For all current map files, `slot_size = 4` bytes (a `uint32` in little-endian byte order). Uninitialized slots are zero-filled. An all-zero slot means "no index" for that element ID.

**Total window size on disk (NO_COMPRESSION):** `items_per_block × slot_size = 65536 × 4 = 262144` bytes = 256 KiB = 8 physical blocks.

```cpp
// src/template_db/random_file.h:128–158 (write, NO_COMPRESSION path)
uint32 data_size = compression_factor;  // = 8
void* target = cache.ptr;              // no compression: write cache directly
// ...
val_file.seek(disk_pos * block_size);
val_file.write(target, block_size * data_size);   // 32768 * 8 = 262144 bytes

// src/template_db/random_file.h:173–175 (read, NO_COMPRESSION path)
val_file.seek(blocks[window].pos * block_size);
val_file.read(cache.ptr, block_size * blocks[window].size);  // size=8, reads 262144 bytes
```

### Compressed block layout (ZLIB / LZ4)

If `compression_method` is `ZLIB_COMPRESSION` (1) or `LZ4_COMPRESSION` (2), each window is stored as a compressed blob, zero-padded to a whole number of physical blocks:

```
Offset              Size                    Description
------              ----                    -----------
0                   compressed_size         ZLIB or LZ4 compressed data
compressed_size     (padding)               Zero bytes to fill out to
                                            entry.size × physical_block_bytes
```

The decompressed output is `decompressed_block_size` bytes (= `physical_block_size × compression_factor`). The output buffer should be at least `decompressed_block_size` bytes for ZLIB, and `2 × decompressed_block_size` bytes for LZ4 (to handle pathological incompressible expansion; `random_file.h:81`).

```cpp
// src/template_db/random_file.h:176–188 (read, compressed path)
val_file.read(buffer.ptr, block_size * blocks[window].size);
// ZLIB:
Zlib_Inflate().decompress(buffer.ptr, block_size * blocks[window].size,
                          cache.ptr, block_size * compression_factor);
// LZ4:
LZ4_Inflate().decompress(buffer.ptr, block_size * blocks[window].size,
                         cache.ptr, block_size * compression_factor);
```

---

## Value Types

### `Uint32_Index` — used in `nodes.map` (value) and `ways.map` / `relations.map` (key)

**Source:** `src/overpass_api/core/basic_types.h:38–99`

A plain 32-bit value. On disk: 4 bytes, little-endian. For node map values, this is `ll_upper` — the upper 32 bits of the node's Morton-code coordinate (the spatial quadtile key that also appears as the index key in `nodes.bin.idx`).

```cpp
void to_data(void* data) const { *(uint32*)data = value; }
Uint32_Index(void* data) : value(*(uint32*)data) {}
static uint32 max_size_of() { return 4; }
```

**Zero sentinel:** `Uint32_Index(0)` means "no entry" — the element is not in the database (or was deleted). Checked explicitly in the update path: `if (index.val() > 0) ...` (`node_updater.cc:791`).

### `Uint31_Index` — used in `ways.map` and `relations.map` (value)

**Source:** `src/overpass_api/core/basic_types.h:120–163`

Inherits from `Uint32_Index`. Same 4-byte little-endian wire format. Bit 31 (`0x80000000`) is a "geometry" flag: when set, the way or relation spans multiple quadtiles and its index represents a bounding-box tile rather than a single tile. See `nodes-bin-format.md` § Index Key Types for full semantics.

```cpp
static uint32 max_size_of() { return 4; }
```

### `Uint64` — used as key type for node maps

**Source:** `src/overpass_api/core/basic_types.h:166–224`

The key type (node ID) is never stored in the `.map` data file. It is used only to compute the window number and slot offset:

```cpp
window = node_id.val() / items_per_block;   // items_per_block = 65536 for nodes.map
slot   = node_id.val() % items_per_block;
```

The key space is 64-bit but the window number must fit in a `uint32` (implicit narrowing in `move_cache_window`). This limits the maximum addressable node ID to `UINT32_MAX × items_per_block = 4,294,967,295 × 65,536 ≈ 2.8 × 10^14`, far above current OSM usage.

---

## Free-Block List: `.map.shadow`

During a write transaction, freed physical blocks are tracked in the **void-blocks file** `{trunk}.map.shadow`. This is not a shadow copy of the data — it is a sorted free list used by the block allocator.

**Source:** `src/template_db/random_file_index.h:256–290` (read), `src/template_db/random_file_index.h:325–336` (write).

### Format

A flat array of 8-byte entries, no header:

```
Offset within entry  Size  Type    Field  Description
-------------------  ----  ------  -----  -----------------------------------------
0                    4     uint32  size   Number of consecutive free physical blocks
4                    4     uint32  pos    Start physical block number of the free run
```

The array is sorted ascending by `(size, pos)` — size first, so that the allocator can use `std::lower_bound` to find a free run of the right size.

```cpp
// src/template_db/random_file_index.h:265–266 (read)
for (uint32 i = 0; i < void_index_size / 8; ++i)
  void_blocks.push_back(*(std::pair<uint32,uint32>*)(index_buf.ptr + 8*i));

// src/template_db/random_file_index.h:326–335 (write)
std::pair<uint32,uint32>* it_ptr = (std::pair<uint32,uint32>*)(void_index_buf.ptr);
for (each void_block entry)
  *(it_ptr++) = *it;
void_file.write(void_index_buf.ptr, void_blocks.size() * 8);
```

The void-blocks file is only present when a write transaction has been opened on the map. On a fresh or read-only database it may not exist; the allocator then reconstructs free blocks by scanning the index for gaps.

---

## Legacy Index Format

The reader automatically detects the old (pre-version-marker) index format. Detection logic (`random_file_index.h:162–163`):

```cpp
bool read_old_format = (file_name_extension == ".legacy" ||
  (index_size > 0 && *(int32*)index_buf.ptr < 7512));
```

In the legacy format:
- **No 8-byte header** — the file starts directly with entries.
- **Each entry is 4 bytes** (a single `uint32 pos`), not 8.
- No `size` field; the size is assumed to equal `compression_factor`.
- Disk positions are in old-style block units and are multiplied by `compression_factor` when read.

```cpp
// src/template_db/random_file_index.h:219–228 (legacy read path)
while (pos < index_size) {
  Random_File_Index_Entry entry(*(uint32*)(index_buf.ptr + pos), compression_factor);
  if (entry.pos != npos)
    entry.pos *= compression_factor;
  blocks.push_back(entry);
  pos += 4;   // 4-byte entries
}
```

New writers always write the 8-byte header format (version 1007053000).

---

## Block Allocation

Physical blocks are allocated from the data file by `allocate_block()` (`random_file.h:195–248`). The allocator:

1. If the free list (`void_blocks`) is empty, appends `data_size` blocks at the end of the file (`block_count += data_size`).
2. Otherwise, searches the sorted free list for an exact-size match. Uses it if found.
3. If no exact match, splits the largest available free run. If a run of the same size appears twice, that is preferred as a heuristic (avoids fragmentation).
4. Saves the new `(pos, size)` entry into the in-memory `blocks` vector at position `window_number`.

The block count (`block_count`) tracks the total number of physical blocks ever allocated. It is recovered on open by `block_count = file_size / physical_block_size`.

---

## Read/Write Procedure Summary

### Reading a value

```
1. Open {trunk}.map.idx; read header → physical_block_size, compression_factor, compression_method
2. Read all 8-byte entries into blocks[]; len = (idx_file_size - 8) / 8
3. Compute window = element_id / items_per_block
               slot   = element_id % items_per_block
   where items_per_block = physical_block_size × compression_factor / slot_size
4. If window >= len or blocks[window].pos == 0xFFFFFFFF:
       return 0  (no entry)
5. Open {trunk}.map; seek to blocks[window].pos × physical_block_size
6. Read blocks[window].size × physical_block_size bytes into raw_buf
7. If NO_COMPRESSION:  decoded_buf = raw_buf (no-op)
   If ZLIB:            decoded_buf = zlib_decompress(raw_buf, physical_block_size × compression_factor)
   If LZ4:             decoded_buf = lz4_decompress(raw_buf, physical_block_size × compression_factor)
                       (use 2× output buffer for safety)
8. value = *(uint32*)(decoded_buf + slot × slot_size)
9. Return value  (0 means "not mapped")
```

### Writing a value

```
1. Open both files as above; load blocks[] and void_blocks[] from .map.idx / .map.shadow
2. Compute window and slot as above
3. If window >= blocks.size() or blocks[window].pos == 0xFFFFFFFF:
       zero-fill a new cache buffer of size physical_block_size × compression_factor
   Else:
       read and decompress the existing window into cache (steps 5–7 above)
4. Write *(uint32*)(cache + slot × slot_size) = new_value
5. On flush (cache eviction or close):
       If NO_COMPRESSION:  raw_buf = cache; data_size = compression_factor
       If ZLIB/LZ4:        raw_buf = compress(cache); data_size = ceil(compressed_size / physical_block_size)
       disk_pos = allocate_block(data_size)  (from void_blocks or end-of-file)
       blocks[window] = (disk_pos, data_size)
       write raw_buf to .map at disk_pos × physical_block_size
6. On close: write updated blocks[] to .map.idx; write void_blocks[] to .map.shadow
```

---

## Visual Layout

```
nodes.map.idx (default, NO_COMPRESSION, nodes.map)
┌────────────────────────────────────────────────┐
│  [0..3]  1007053000  (FILE_FORMAT_VERSION)     │
│  [4]     15          (block_size_log2: 2^15=32KiB) │
│  [5]     3           (comp_factor_log2: 2^3=8) │
│  [6..7]  0           (NO_COMPRESSION)          │
│                                                │
│  Entry 0  [8..15]:   pos=A  size=8  ← window 0: node IDs 0–65535      │
│  Entry 1  [16..23]:  pos=B  size=8  ← window 1: node IDs 65536–131071 │
│  Entry 2  [24..31]:  pos=FFFFFFFF size=? ← window 2: never written    │
│  ...                                           │
└────────────────────────────────────────────────┘

nodes.map  (8 physical blocks = 256 KiB per window, NO_COMPRESSION)
┌────────────────────────────────────────────────────────┐
│  Block A×32KiB .. A×32KiB+261143:                      │
│    slot[0]  [0..3]   Uint32_Index for node_id 0        │
│    slot[1]  [4..7]   Uint32_Index for node_id 1        │
│    ...                                                 │
│    slot[65535] [262140..262143]  Uint32_Index for node_id 65535 │
│                                                        │
│  Block B×32KiB .. B×32KiB+261143:                      │
│    slot[0]  [0..3]   Uint32_Index for node_id 65536    │
│    ...                                                 │
└────────────────────────────────────────────────────────┘
```

---

## Source File Reference

| Component | File | Key lines |
|-----------|------|-----------|
| `Random_File<Key,Value>` — get/put, block I/O | `src/template_db/random_file.h` | 37–251 |
| `Random_File_Index` — index read/write | `src/template_db/random_file_index.h` | 47–357 |
| `Random_File_Index_Entry` struct | `src/template_db/random_file_index.h` | 35–44 |
| `FILE_FORMAT_VERSION` constant (1007053000) | `src/template_db/random_file_index.h` | 74 |
| Index file write (header + entries) | `src/template_db/random_file_index.h` | 294–323 |
| Index file read (new format) | `src/template_db/random_file_index.h` | 166–210 |
| Index file read (legacy format) | `src/template_db/random_file_index.h` | 213–230 |
| Void-blocks file read | `src/template_db/random_file_index.h` | 256–290 |
| Void-blocks file write | `src/template_db/random_file_index.h` | 325–336 |
| `move_cache_window()` — block I/O, compression | `src/template_db/random_file.h` | 113–190 |
| `allocate_block()` — free-list allocator | `src/template_db/random_file.h` | 194–248 |
| `Uint32_Index` struct | `src/overpass_api/core/basic_types.h` | 38–99 |
| `Uint31_Index` struct | `src/overpass_api/core/basic_types.h` | 120–163 |
| `Uint64` struct (node ID type) | `src/overpass_api/core/basic_types.h` | 166–224 |
| File properties (block size, compression) | `src/overpass_api/core/settings.cc` | 37–89, 125, 137, 149, 256–318 |
| `get_map_block_size()`, `get_map_compression_*()` | `src/overpass_api/core/settings.cc` | 54–56 |
| Node map usage (`nodes.map`) | `src/overpass_api/osm-backend/node_updater.cc` | 785–793 |
| Way map usage (`ways.map`) | `src/overpass_api/osm-backend/dump_file.cc` | 295 |
| Attic map usage | `src/overpass_api/data/collect_members.cc` | 401–442 |
| Map lookup in query execution | `src/overpass_api/data/collect_items.h` | 627–638 |
