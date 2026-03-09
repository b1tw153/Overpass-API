# OSM Binary File Formats: Tag Data Files

## Overview

Overpass API stores OSM tag data in three families of paired binary files, one family per element type (nodes, ways, relations). Each family has three file roles:

| Role | Purpose | Index key type | Value type |
|------|---------|----------------|------------|
| **Local** | Tags indexed by spatial tile | `Tag_Index_Local` | `Id_Type` (object ID) |
| **Global** | Tags indexed by (key, value) pair | `Tag_Index_Global_KVI` | `Tag_Object_Global<Id_Type>` |
| **Frequent** | Frequency metadata for global tag optimisation | `String_Index` (tag key) | `Frequent_Value_Entry` |

All files use the same **Block Backend** container format described in `nodes-bin-format.md`. This document covers only the tag-specific index key and value record layouts.

### Current (live) file names

| Element | Local tags | Global tags | Frequent tags |
|---------|-----------|-------------|---------------|
| Node | `node_tags_local.bin/.idx` | `node_tags_global.bin/.idx` | `node_frequent_tags.bin/.idx` |
| Way | `way_tags_local.bin/.idx` | `way_tags_global.bin/.idx` | `way_frequent_tags.bin/.idx` |
| Relation | `relation_tags_local.bin/.idx` | `relation_tags_global.bin/.idx` | `relation_frequent_tags.bin/.idx` |
| Area | `area_tags_local.bin/.idx` | `area_tags_global.bin/.idx` | *(none)* |

### Attic (historical) file names

Attic tag files follow the same pattern with an `_attic` suffix on the trunk name:
`node_tags_local_attic.bin/.idx`, `node_tags_global_attic.bin/.idx`, `node_frequent_tags_attic.bin/.idx`, and likewise for ways and relations.

### Legacy global tag file (pre-0.7.56)

Before version 0.7.56, the global tag files used a simpler `Tag_Index_Global_Until756` format (no `idx` split field). The on-disk file name is the same (`node_tags_global.bin`, etc.); the distinction is tracked by the `min_version` parameter in `OSM_File_Properties`. A migration function (`migrate_current_global_tags` / `migrate_attic_global_tags` in `tags_global_writer.h`) converts these files to the KVI format on first start after an upgrade.

---

## File Properties

Configured in `src/overpass_api/core/settings.cc`:

| File | Block size param | Physical block | Compression |
|------|-----------------|----------------|-------------|
| `node_tags_local` (line 126) | 128 KiB | 16 KiB | LZ4 / ZLIB |
| `node_tags_global` (line 128) | 128 KiB | 16 KiB | LZ4 / ZLIB |
| `node_frequent_tags` (line 134) | 512 KiB | 64 KiB | LZ4 / ZLIB |
| `way_tags_local` (line 138) | 128 KiB | 16 KiB | LZ4 / ZLIB |
| `way_tags_global` (line 140) | 128 KiB | 16 KiB | LZ4 / ZLIB |
| `way_frequent_tags` (line 146) | 512 KiB | 64 KiB | LZ4 / ZLIB |
| `relation_tags_local` (line 152) | 128 KiB | 16 KiB | LZ4 / ZLIB |
| `relation_tags_global` (line 154) | 128 KiB | 16 KiB | LZ4 / ZLIB |
| `relation_frequent_tags` (line 160) | 512 KiB | 64 KiB | LZ4 / ZLIB |
| `area_tags_local` (line 202) | 256 KiB | 32 KiB | LZ4 / ZLIB |
| `area_tags_global` (line 204) | 512 KiB | 64 KiB | LZ4 / ZLIB |

Block size parameter semantics follow the same `physical = param / 8` rule as the skeleton files; see `nodes-bin-format.md § File Properties`.

---

## Index Key Formats

### `String_Index` — tag key only

**Source:** `src/overpass_api/core/type_tags.h:60–123`

Used as the index key in frequent-tag files. Sorts lexicographically by the key string.

```
Offset  Size  Type    Field       Description
------  ----  ------  ----------  ------------------------------------
0       2     uint16  key_length  Byte length of the key string
2       N     bytes   key         UTF-8 tag key (N = key_length)
```

Total size: `2 + key_length`

```cpp
// to_data / from_data  (type_tags.h:99–103 / 67–69)
*(uint16*)data = key.length();
memcpy((uint8*)data + 2, key.data(), key.length());

key = std::string(((int8*)data + 2), *(uint16*)data);
```

Ordering: lexicographic on `key`.

---

### `Tag_Index_Local` — tag + coarse spatial tile

**Source:** `src/overpass_api/core/type_tags.h:126–239`

Used as the index key in local-tag files. Groups all objects that share a (key, value, tile) triple into the same block. The spatial index stored is the **coarse** part of the object's tile, i.e., `Uint31_Index.val() & 0x7fffff00`, which identifies a 256-element block of tiles.

```
Offset  Size  Type    Field         Description
------  ----  ------  -----------   -----------------------------------------------
0       2     uint16  key_length    Byte length of key string (K)
2       2     uint16  value_length  Byte length of value string (V)
4       3     uint24  coarse_index  (index >> 8) & 0x7FFFFF, stored little-endian
                                    (23-bit coarse spatial tile, LE)
7       K     bytes   key           UTF-8 tag key
7+K     V     bytes   value         UTF-8 tag value
```

Total size: `7 + key_length + value_length`

**Implementation note:** `to_data` writes `index >> 8` as a 4-byte `uint32` at offset 4 (bytes 4–7), which is harmless because `index >> 8` never exceeds 23 bits — byte 7 is zero on write. `memcpy` immediately overwrites byte 7 with the first byte of the key. On read, `(*((uint32*)data + 1)) << 8` reconstructs `index`: the `<< 8` shift discards the top byte (which contains key[0]), recovering the correct value from bytes 4–6.

```cpp
// to_data  (type_tags.h:201–208)
*(uint16*)data           = key.length();       // bytes 0-1
*((uint16*)data + 1)     = value.length();     // bytes 2-3
*((uint32*)data + 1)     = index >> 8;         // bytes 4-7 (byte 7 written as 0)
memcpy((uint8*)data + 7, key.data(), key.length());           // bytes 7 .. 7+K-1
memcpy((uint8*)data + 7 + key.length(), value.data(), value.length()); // 7+K ..

// from_data constructor  (type_tags.h:143–149)
index = (*((uint32*)data + 1)) << 8;           // shift discards contaminated byte 7
key   = std::string(((int8*)data + 7), *(uint16*)data);
value = std::string(((int8*)data + 7 + key.length()), *((uint16*)data + 1));
```

**Ordering** (block backend sort key, `less()` / `leq()` at type_tags.h:153–180):
1. `(index >> 8) & 0x7FFFFF` — coarse tile (top 23 bits of 31-bit index), ascending
2. `index >> 8` — full stored value (distinguishes flag bit in bit 31), ascending
3. `key` — lexicographic
4. `value` — lexicographic

The `operator<` used for in-memory sorting follows the same order but compares the full `index & 0x7FFFFFFF` first, then the full `index`, then key, then value.

---

### `Tag_Index_Global_KVI` — key + value + spatial split

**Source:** `src/overpass_api/core/type_tags.h:415–509`

`typedef Tag_Index_Global_KVI Tag_Index_Global;`

Used as the index key in current global-tag files (version ≥ 0.7.56). The `idx` field is a spatial sub-index used to shard high-cardinality `(key, value)` pairs across multiple blocks; for rare tags it is always 0.

```
Offset  Size  Type    Field         Description
------  ----  ------  -----------   -----------------------------------------------
0       2     uint16  key_length    Byte length of key string (K)
2       2     uint16  value_length  Byte length of value string (V)
4       4     uint32  idx           Spatial split index (LE); see KVI split levels below
8       K     bytes   key           UTF-8 tag key
8+K     V     bytes   value         UTF-8 tag value
```

Total size: `8 + key_length + value_length`

```cpp
// to_data  (type_tags.h:478–484)
*(uint16*)data           = key.length();    // bytes 0-1
*((uint16*)data + 1)     = value.length();  // bytes 2-3
*(uint32*)((int8*)data + 4) = idx;          // bytes 4-7
memcpy((uint8*)data + 8, key.data(), key.length());
memcpy((uint8*)data + 8 + key.length(), value.data(), value.length());

// from_data constructor  (type_tags.h:423–427)
key   = std::string(((int8*)data + 8), *(uint16*)data);
value = std::string(((int8*)data + 8 + key.length()), *((uint16*)data + 1));
idx   = *(uint32*)((int8*)data + 4);
```

**Ordering** (`operator<`, type_tags.h:487–494):
1. `key` — lexicographic
2. `value` — lexicographic
3. `idx` — ascending

#### KVI split levels

**Source:** `src/overpass_api/osm-backend/tags_global_writer.h:82–94`

The `idx` field is the object's `Uint31_Index` value masked to a prefix of 0, 8, 16, or 24 bits depending on how many objects share the same `(key, value)` pair:

| Total objects with this (key, value) | Level | idx mask | idx meaning |
|--------------------------------------|-------|----------|-------------|
| < 8,192 | 0 | `0x00000000` | All in one block; `idx = 0` for all |
| 8,192 – 524,287 | 8 | `0xFF000000` | Top 8 bits of spatial index |
| 524,288 – 33,554,431 | 16 | `0xFFFF0000` | Top 16 bits of spatial index |
| ≥ 33,554,432 | 24 | `0xFFFFFF00` | Top 24 bits of spatial index |

```cpp
// tags_global_writer.h:88–94
inline uint calc_tag_split_level(uint64 cnt)
{
  return cnt < 8*1024   ? 0
       : cnt < 512*1024 ? 8
       : cnt < 32*1024*1024 ? 16
       : 24;
}
```

At level 0, every object with the same `(key, value)` pair shares a single `Tag_Index_Global_KVI` entry with `idx = 0`. At higher levels the objects are distributed across up to 256 (level 8), 65,536 (level 16), or 16,777,216 (level 24) distinct `Tag_Index_Global_KVI` entries, each covering a spatial region.

When the count for a `(key, value)` pair crosses a level threshold, `reorganize_tag_split_level()` reads all objects for that pair, regroups them under the new `idx` mask, and writes them back. The threshold information is stored in the corresponding `*_frequent_tags` file so that subsequent updates apply the correct grouping without re-reading the entire global file.

---

### `Tag_Index_Global_Until756` — key + value (legacy)

**Source:** `src/overpass_api/core/type_tags.h:328–412`

Used in global tag files written before version 0.7.56. No `idx` field; all objects for a `(key, value)` pair are in one index group regardless of cardinality.

```
Offset  Size  Type    Field         Description
------  ----  ------  -----------   ------------------------------------
0       2     uint16  key_length    Byte length of key string (K)
2       2     uint16  value_length  Byte length of value string (V)
4       K     bytes   key           UTF-8 tag key
4+K     V     bytes   value         UTF-8 tag value
```

Total size: `4 + key_length + value_length`

**Ordering:** lexicographic by `key`, then by `value`.

---

## Value Record Formats

### `Id_Type` — local-tag value (object ID only)

Local-tag files store only the object's numeric ID as the value — the full tag is encoded in the index key (`Tag_Index_Local`). An ID lookup for all objects with a given `(key, value, tile)` therefore reads only compact integer lists with no string duplication.

| File family | `Id_Type` | Serialized size |
|-------------|-----------|-----------------|
| node local tags | `Uint64` (node ID) | 8 bytes |
| way local tags | `Uint32_Index` (way ID) | 4 bytes |
| relation local tags | `Uint32_Index` (relation ID) | 4 bytes |
| **area local tags** | `Uint32_Index` (area ID) | **4 bytes** |

These are the same `Id_Type` typedefs used by the corresponding skeleton structures (`Node_Skeleton::Id_Type`, `Way_Skeleton::Id_Type`, `Relation_Skeleton::Id_Type`). Serialisation is the same fixed-size little-endian integer write used by those types.

For attic local tags, the value is `Attic<Id_Type>`, which appends a 5-byte timestamp (see `nodes-bin-format.md § Attic<Node_Skeleton>`), yielding 13 bytes for nodes and 9 bytes for ways/relations.

Area tag files have no attic variant (areas are a computed, non-historical dataset).

---

### `Tag_Object_Global<Id_Type>` — global-tag value

**Source:** `src/overpass_api/core/type_tags.h:515–568`

Global-tag files store both the object's ID and its spatial index as the value. The spatial index is needed because the file is keyed by `(key, value)` — the caller cannot know which tile the object lives in from the index alone.

```
Offset  Size  Type    Field    Description
------  ----  ------  -------  ---------------------------------------------------------
0       3     uint24  idx>>8   (Uint31_Index.val() >> 8) & 0x7FFFFF, stored LE
                               — 23-bit coarse spatial index of the tagged object
3       N     bytes   id       Object ID (N = Id_Type::size_of())
```

| Element type | `Id_Type` | N | Total size |
|--------------|-----------|---|------------|
| Node | `Uint64` | 8 | 11 bytes |
| Way | `Uint32_Index` | 4 | 7 bytes |
| Relation | `Uint32_Index` | 4 | 7 bytes |
| **Area** | `Uint32_Index` | 4 | **7 bytes** |

The same 3-byte-integer trick used by `Tag_Index_Local` is applied here: `to_data` writes `(idx.val() >> 8) & 0x7FFFFF` as a `uint32` at offset 0 (byte 3 = 0 on write), then `id.to_data` overwrites byte 3 with the first byte of the ID. `from_data` reads `(*((uint32*)data) << 8) & 0xFFFFFF00` and the `<< 8` shift discards the contaminated byte 3.

```cpp
// to_data  (type_tags.h:543–546)
*(uint32*)data = ((idx.val() >> 8) & 0x7fffff);   // bytes 0-3; byte 3 = 0
id.to_data((void*)((uint8*)data + 3));             // overwrites byte 3 with id[0]

// from_data constructor  (type_tags.h:527–530)
idx = Uint31_Index(((*((uint32*)data)) << 8) & 0xffffff00);  // byte 3 discarded
id  = Id_Type((void*)((uint8*)data + 3));
```

**Ordering** (`operator<`, type_tags.h:549–557): primary by `id`, secondary by `idx`. (The block backend sorts records within an index group by their natural `operator<`.)

For attic global tags, the value is `Attic<Tag_Object_Global<Id_Type>>`, which appends a 5-byte timestamp, yielding 16 bytes for nodes and 12 bytes for ways/relations.

---

### `Frequent_Value_Entry` — frequent-tag value

**Source:** `src/overpass_api/osm-backend/tags_global_writer.h:29–77`

Frequent-tag files track, for each tag key, which tag values have crossed a KVI level threshold. A `Frequent_Value_Entry` records the value string, its accumulated object count, and its current split level. This file is read at every global-tag write to determine how to distribute objects across `Tag_Index_Global_KVI` entries.

```
Offset  Size  Type    Field         Description
------  ----  ------  -----------   --------------------------------------------------
0       8     uint64  count         Total number of objects with this (key, value) pair
8       1     uint8   level         Current split level: 0, 8, 16, or 24
9       2     uint16  value_length  Byte length of value string (V)
11      V     bytes   value         UTF-8 tag value
```

Total size: `11 + value_length`

```cpp
// to_data  (tags_global_writer.h:59–65)
*(uint64*)data                   = count;
*((uint8*)data + 8)              = level;
*(uint16*)((uint8*)data + 9)     = value.size();
memcpy((int8*)data + 11, &value[0], value.size());

// from_data constructor  (tags_global_writer.h:42–46)
count = *(uint64*)data;
level = *((uint8*)data + 8);
value = std::string((int8*)data + 11, *(uint16*)((uint8*)data + 9));
```

**Ordering** (`operator<`, tags_global_writer.h:68–71): lexicographic by `value`.

---

## Logical Structure

The three file roles together form a complete tag index:

```
Local file  (Tag_Index_Local → Id_Type)
  Key:   (coarse_tile, key_string, value_string)
  Value: object_id
  Use:   "which objects in tile T have tag key=value?"
         → range-query the block backend over coarse_tile range

Global file  (Tag_Index_Global_KVI → Tag_Object_Global)
  Key:   (key_string, value_string, spatial_split_idx)
  Value: (object_spatial_idx, object_id)
  Use:   "which objects anywhere have tag key=value?"
         → range-query over (key, value, 0) .. (key, value+'\0', ∞)
         then filter by bounding box using object_spatial_idx

Frequent file  (String_Index → Frequent_Value_Entry)
  Key:   key_string
  Value: (value_string, count, level)
  Use:   at write time, look up the current level for each (key, value)
         so objects are placed in the correct Tag_Index_Global_KVI entry
```

---

## Visual Layouts

### Local tag file block payload

```
(decompressed block buffer — local tag file, e.g. node_tags_local.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: Tag_Index_Local ───────────────────────────────── ─ │
│  [4..7]   next_idx_offset     (uint32, byte offset of next group)    │
│  [8..9]   key_length          (uint16)  ─┐                           │
│  [10..11] value_length        (uint16)   │ index key                 │
│  [12..14] coarse_index>>8     (24-bit LE)│ (Tag_Index_Local)         │
│  [15..15+K-1]  key            (K bytes) ─┘                           │
│  [15+K..15+K+V-1] value       (V bytes)                              │
│  ── value records (object IDs) ────────────────────────────────────  │
│  [15+K+V .. next_idx_offset-1]                                       │
│     node IDs: 8 bytes each  (Uint64, little-endian)                  │
│     way/relation IDs: 4 bytes each  (Uint32_Index, little-endian)    │
│                                                                      │
│  ── Index Group 2 (starts at next_idx_offset) ─────────────────────  │
│  ...                                                                 │
│  [total_payload_size .. block_size-1]  zero padding                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Global tag file block payload (KVI format)

```
(decompressed block buffer — global tag file, e.g. node_tags_global.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: Tag_Index_Global_KVI ──────────────────────────── ─ │
│  [4..7]   next_idx_offset     (uint32)                               │
│  [8..9]   key_length          (uint16) ─┐                            │
│  [10..11] value_length        (uint16)  │ index key                  │
│  [12..15] idx                 (uint32)  │ (Tag_Index_Global_KVI)     │
│  [16..16+K-1]  key            (K bytes) │                            │
│  [16+K..16+K+V-1] value       (V bytes)─┘                            │
│  ── value records (Tag_Object_Global) ─────────────────────────────  │
│  Per record (node, 11 bytes):                                        │
│    [+0..+2]   spatial_idx>>8  (24-bit LE, Uint31_Index of object)    │
│    [+3..+10]  node_id         (uint64 LE)                            │
│  Per record (way/relation, 7 bytes):                                 │
│    [+0..+2]   spatial_idx>>8  (24-bit LE)                            │
│    [+3..+6]   way/rel_id      (uint32 LE)                            │
│                                                                      │
│  ── Index Group 2 (starts at next_idx_offset) ─────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

### Frequent tag file block payload

```
(decompressed block buffer — frequent tag file, e.g. node_frequent_tags.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: String_Index (one per tag key) ─────────────────── │
│  [4..7]   next_idx_offset     (uint32)                               │
│  [8..9]   key_length          (uint16) ─┐ index key (String_Index)  │
│  [10..10+K-1] key             (K bytes)─┘                            │
│  ── value records (Frequent_Value_Entry) ──────────────────────────  │
│  Per record (11+V bytes, one per high-frequency value):              │
│    [+0..+7]   count           (uint64 LE, total objects with key=val)│
│    [+8]       level           (uint8:  0, 8, 16, or 24)             │
│    [+9..+10]  value_length    (uint16 LE)                            │
│    [+11..+11+V-1] value       (V bytes, UTF-8)                       │
│                                                                      │
│  ── Index Group 2 (next tag key) ──────────────────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Read/Write Pseudocode

### Reading all objects with tag `key=value` from the local file

```
function read_local_tags(file, key, value, coarse_tile_set):
    # Build a set of index ranges, one per coarse tile
    ranges = []
    for tile in coarse_tile_set:
        lo = Tag_Index_Local(index = tile,        key = "",     value = "")
        hi = Tag_Index_Local(index = tile + 0x100, key = "",     value = "")
        ranges.append([lo, hi))

    results = []
    for (idx_key, obj_id) in block_backend.range_iterate(file, ranges):
        if idx_key.key == key and idx_key.value == value:
            results.append((idx_key.index, obj_id))
    return results
    # idx_key.index & 0x7fffff00 = coarse tile; obj_id identifies the object
```

### Reading all objects with tag `key=value` from the global file

```
function read_global_tags(file, key, value):
    lo = Tag_Index_Global_KVI(key = key,   value = value,        idx = 0)
    hi = Tag_Index_Global_KVI(key = key,   value = value + '\0', idx = 0)
    ranges = [[lo, hi))

    results = []
    for (idx_key, tag_obj) in block_backend.range_iterate(file, ranges):
        # idx_key.key == key, idx_key.value == value (guaranteed by range)
        # tag_obj.idx = coarse spatial tile of the object
        # tag_obj.id  = object ID
        results.append((tag_obj.idx, tag_obj.id))
    return results
```

### Writing local tags (update path)

```
function update_local_tags(file, to_delete, to_insert):
    # to_delete: map Tag_Index_Local -> set<Id_Type>
    # to_insert: map Tag_Index_Local -> vector<Id_Type>
    block_backend.update(file, to_delete, to_insert)
    # Block backend merges old and new data, rewriting affected blocks
```

### Writing global tags (update path with KVI level management)

```
function update_global_tags(tags_file, freq_file, to_delete, to_insert):
    # Step 1: load current split levels from the frequent file
    frequent = {}   # map key_string -> list[Frequent_Value_Entry]
    for (str_idx, fve) in block_backend.flat_iterate(freq_file):
        frequent[str_idx.key].append(fve)
    for entries in frequent.values():
        sort(entries)   # by value string

    # Step 2: remap object idx fields in to_delete / to_insert to match
    #         the current level masks for each (key, value) pair
    adapt_data_to_actual_idx(to_delete, frequent)
    adapt_data_to_actual_idx(to_insert, frequent)
    #   For each (key, value) in to_delete / to_insert that has an entry
    #   in `frequent` at level L, replace each object's idx with:
    #       object.idx & (0xFFFFFFFF << (32 - L))

    # Step 3: write the updated data and collect per-(key,value) count deltas
    count_deltas = {}   # Tag_Index_Global_KVI -> Delta_Count(before, after)
    block_backend.update(tags_file, to_delete, to_insert, count_deltas)

    # Step 4: check whether any (key, value) pair has crossed a level threshold
    freq_to_delete = {}
    freq_to_insert = {}
    for (kv, delta) in count_deltas:
        new_count = get_count_from_frequent(frequent, kv.key, kv.value) + delta.after - delta.before
        new_level = calc_tag_split_level(new_count)
        old_level = get_level_from_frequent(frequent, kv.key, kv.value)
        if new_level > old_level:
            # Reorganise: read all objects for (key, value), regroup by new mask
            reorganize_tag_split_level(tags_file, new_level, kv.key, kv.value)
            freq_to_delete[kv.key].add(old_entry)
            freq_to_insert[kv.key].append(Frequent_Value_Entry(kv.value, new_count, new_level))

    # Step 5: persist updated split levels
    block_backend.update(freq_file, freq_to_delete, freq_to_insert)
```

#### `adapt_data_to_actual_idx` detail

```
function adapt_data_to_actual_idx(obj_map, frequent):
    # For each (key, value) pair that has a known level, ensure every
    # Tag_Index_Global_KVI entry in obj_map uses the correct idx mask.
    for (key, entries) in frequent:
        for fve in entries:   # fve.value, fve.level
            mask = 0xFFFFFFFF << (32 - fve.level)
            # Collect all map entries with this (key, value), regardless of idx
            matching = obj_map.range(key=key, value=fve.value)
            for (old_kv, objs) in matching:
                new_kv = Tag_Index_Global_KVI(key, fve.value, objs[0].idx.val() & mask)
                obj_map[new_kv] += objs   # merge into correctly-bucketed entry
            remove matching from obj_map
```

#### `reorganize_tag_split_level` detail

```
function reorganize_tag_split_level(tags_file, target_level, key, value):
    mask = 0xFFFFFFFF << (32 - target_level)

    # Read all current objects for this (key, value)
    to_delete = {}
    lo = Tag_Index_Global_KVI(key, value, 0)
    hi = Tag_Index_Global_KVI(key, value + '\0', 0)
    for (kv, obj) in block_backend.range_iterate(tags_file, [[lo, hi))):
        to_delete[kv].add(obj)

    # Re-bucket by applying the new mask to each object's spatial index
    to_insert = {}
    for (kv, objs) in to_delete:
        for obj in objs:
            new_idx = obj.idx.val() & mask
            to_insert[Tag_Index_Global_KVI(key, value, new_idx)].append(obj)

    block_backend.update(tags_file, to_delete, to_insert)
```

---

## Source File Reference

| Component | File | Lines |
|-----------|------|-------|
| `String_Index` | `src/overpass_api/core/type_tags.h` | 60–123 |
| `Tag_Index_Local` | `src/overpass_api/core/type_tags.h` | 126–239 |
| `Tag_Index_Global_Until756` | `src/overpass_api/core/type_tags.h` | 328–412 |
| `Tag_Index_Global_KVI` / `Tag_Index_Global` | `src/overpass_api/core/type_tags.h` | 415–512 |
| `Tag_Object_Global<Id_Type>` | `src/overpass_api/core/type_tags.h` | 515–568 |
| `Tag_Entry<Id_Type>` (in-memory helper) | `src/overpass_api/core/type_tags.h` | 38–45 |
| `Frequent_Value_Entry` | `src/overpass_api/osm-backend/tags_global_writer.h` | 29–77 |
| `calc_tag_split_level()` | `src/overpass_api/osm-backend/tags_global_writer.h` | 82–94 |
| `adapt_data_to_actual_idx()` | `src/overpass_api/osm-backend/tags_global_writer.h` | 142–162 |
| `reorganize_tag_split_level()` | `src/overpass_api/osm-backend/tags_global_writer.h` | 166–188 |
| `Freq_Tags_Updater<>` | `src/overpass_api/osm-backend/tags_global_writer.h` | 192–235 |
| `update_global_tags()` | `src/overpass_api/osm-backend/tags_global_writer.h` | 239–292 |
| `migrate_current_global_tags()` | `src/overpass_api/osm-backend/tags_global_writer.h` | 427–449 |
| `Tag_Store` (read-side caching layer) | `src/overpass_api/data/tag_store.h` | — |
| File property accessors | `src/overpass_api/data/filenames.h` | 78–285 |
| `OSM_File_Properties` declarations | `src/overpass_api/core/settings.cc` | 126–161, 202–205 |
| `update_area_tags_local()` | `src/overpass_api/osm-backend/area_updater.cc` | 214–261 |
| `update_area_tags_global()` | `src/overpass_api/osm-backend/area_updater.cc` | 263–305 |
| Block backend (container layer) | `src/template_db/block_backend.h` | — |
