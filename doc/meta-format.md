# OSM Binary File Formats: Meta Data Files

## Overview

When Overpass API is started with `--meta=yes` (or `--meta=attic`), five additional binary files are written per database instance. They store per-element metadata (version, timestamp, changeset, user) and a user-id → name mapping.

| File | Index key | Value type | Purpose |
|------|-----------|------------|---------|
| `nodes_meta.bin` | `Uint32_Index` (spatial tile) | `OSM_Element_Metadata_Skeleton<Uint64>` | Metadata for current nodes |
| `ways_meta.bin` | `Uint31_Index` (spatial tile) | `OSM_Element_Metadata_Skeleton<Uint32_Index>` | Metadata for current ways |
| `relations_meta.bin` | `Uint31_Index` (spatial tile) | `OSM_Element_Metadata_Skeleton<Uint32_Index>` | Metadata for current relations |
| `user_data.bin` | `Uint32_Index` (`user_id & 0xFFFFFF00`) | `User_Data` | User ID → display name |
| `user_indices.bin` | `Uint32_Index` (user ID) | `Uint31_Index` | User ID → set of spatial tiles edited |

All five use the Block Backend container format described in `nodes-bin-format.md`.

### Attic (historical) variants

When `--meta=attic` is used, three additional files are written that store metadata for every historical version of each element:

| File | Index key | Value type |
|------|-----------|------------|
| `nodes_meta_attic.bin` | `Uint32_Index` | `OSM_Element_Metadata_Skeleton<Uint64>` |
| `ways_meta_attic.bin` | `Uint31_Index` | `OSM_Element_Metadata_Skeleton<Uint32_Index>` |
| `relations_meta_attic.bin` | `Uint31_Index` | `OSM_Element_Metadata_Skeleton<Uint32_Index>` |

The format is identical to the current files. Multiple records per element ID accumulate over time (one per version), distinguished by the `timestamp` field in `operator<`.

---

## File Properties

Configured in `src/overpass_api/core/settings.cc` (Meta_Settings constructor, lines 223–237):

| File | Settings line | Block size param | Physical block | Index type |
|------|--------------|-----------------|----------------|------------|
| `user_data` | 225 | 512 KiB | 64 KiB | `Uint32_Index` |
| `user_indices` | 227 | 128 KiB | 16 KiB | `Uint32_Index` |
| `nodes_meta` | 229 | 128 KiB | 16 KiB | `Node::Index` = `Uint32_Index` |
| `ways_meta` | 231 | 128 KiB | 16 KiB | `Way::Index` = `Uint31_Index` |
| `relations_meta` | 233 | 128 KiB | 16 KiB | `Relation::Index` = `Uint31_Index` |

Attic variants use the same block sizes as their current equivalents. The `map_block_size_` parameter is 0 for all meta files (no `.map` random-access companion file).

---

## Timestamp Encoding

**Source:** `src/overpass_api/core/datatypes.h:623–732`

All timestamps in metadata files use a custom **40-bit packed datetime** format, not Unix time. The 40 bits are allocated as follows:

```
Bit  39          26 25       22 21    17 16   12 11      6 5       0
     ┌──────────────┬──────────┬────────┬───────┬──────────┬────────┐
     │  year (14b)  │ month(4b)│ day(5b)│hour(5b)│minute(6b)│sec(6b) │
     └──────────────┴──────────┴────────┴───────┴──────────┴────────┘
```

| Field | Bits | Range | Shift |
|-------|------|-------|-------|
| year | 14 | 0–16383 | `<< 26` |
| month | 4 | 1–12 | `<< 22` |
| day | 5 | 1–31 | `<< 17` |
| hour | 5 | 0–23 | `<< 12` |
| minute | 6 | 0–59 | `<< 6` |
| second | 6 | 0–59 | `<< 0` |

```cpp
// datatypes.h:632–641
Timestamp(int year, int month, int day, int hour, int minute, int second) : timestamp(0)
{
  timestamp |= (uint64(year & 0x3fff) << 26);
  timestamp |= ((month  & 0xf)  << 22);
  timestamp |= ((day    & 0x1f) << 17);
  timestamp |= ((hour   & 0x1f) << 12);
  timestamp |= ((minute & 0x3f) << 6);
  timestamp |= (second  & 0x3f);
}
```

The 40-bit value is stored **little-endian in 5 bytes** on disk:

```cpp
// datatypes.h:710–715
void to_data(void* data) const {
  *(uint32*)(pos)       = (timestamp & 0xffffffffull);   // bytes 0–3: lower 32 bits
  *(((uint8*)pos) + 4)  = ((timestamp & 0xff00000000ull) >> 32); // byte 4: bits 32–39
}

// from_data constructor
Timestamp(void* data) : timestamp((*(uint64*)(uint8*)data) & 0xffffffffffull) {}
// Reads 8 bytes but masks to 40 bits; upper 3 bytes are always zero
```

A sentinel value of `0xFFFFFFFFFFFFFFFF` (UINT64_MAX) represents "NOW" (`datatypes.h:683`).

---

## Record Formats

### `OSM_Element_Metadata_Skeleton<Id_Type>` — metadata record

**Source:** `src/overpass_api/core/datatypes.h:481–547`

One record per OSM element per version (current files hold only the latest version; attic files accumulate all versions). The record is **fixed-size** for each element type.

#### For nodes — `Id_Type = Uint64` (8 bytes)

Total size: **25 bytes**

```
Offset  Size  Type    Field      Description
------  ----  ------  ---------  -------------------------------------------------
0       8     uint64  ref        OSM node ID (little-endian)
8       4     uint32  version    Element version number (little-endian)
12      5     uint40  timestamp  Packed 40-bit datetime (see Timestamp Encoding)
17      4     uint32  changeset  OSM changeset ID (little-endian)
21      4     uint32  user_id    OSM user ID (little-endian)
```

#### For ways and relations — `Id_Type = Uint32_Index` (4 bytes)

Total size: **21 bytes**

```
Offset  Size  Type    Field      Description
------  ----  ------  ---------  -------------------------------------------------
0       4     uint32  ref        OSM way / relation ID (little-endian)
4       4     uint32  version    Element version number (little-endian)
8       5     uint40  timestamp  Packed 40-bit datetime (see Timestamp Encoding)
13      4     uint32  changeset  OSM changeset ID (little-endian)
17      4     uint32  user_id    OSM user ID (little-endian)
```

**Implementation note — 5-byte integer trick:** `to_data` writes `timestamp` as a full `uint64` at offset `sizeof(Id_Type) + 4`, placing 8 bytes there (bytes `+4` through `+11`). Since `timestamp ≤ 0xffffffffffull`, bytes `+9` through `+11` are zero on write. The immediately following `changeset` write at offset `+9` then overwrites those three zeros with the changeset value. On read, `*(uint64*)(...+4) & 0xffffffffffull` masks off bits 40–63 (which now contain the first three bytes of `changeset`), recovering the clean 40-bit timestamp.

```cpp
// datatypes.h:525–532
void to_data(void* data) const {
  *(Id_Type*)data = ref;                                                // bytes 0..sizeof(Id_Type)-1
  *(uint32*)((int8*)data + sizeof(Id_Type))     = version;              // bytes +0..+3
  *(uint64*)((int8*)data + sizeof(Id_Type) + 4) = timestamp;            // bytes +4..+11 (5 meaningful)
  *(uint32*)((int8*)data + sizeof(Id_Type) + 9) = changeset;            // bytes +9..+12 (overwrites +9..+11)
  *(uint32*)((int8*)data + sizeof(Id_Type) + 13) = user_id;             // bytes +13..+16
}
```

**Ordering** (`operator<`, datatypes.h:534–541): primary by `ref` (element ID), secondary by `timestamp`. The secondary sort by timestamp means that for attic files, multiple versions of the same element sort in chronological order.

**Equality** (`operator==`, datatypes.h:543–545): equality is defined only on `ref` — two records with the same element ID are considered equal regardless of version. This allows the block backend to use element ID as a deletion key.

---

### `User_Data` — user name record

**Source:** `src/overpass_api/core/datatypes.h:423–464`

Stores the mapping from an integer user ID to the OSM display name string. One record per user.

```
Offset  Size  Type    Field         Description
------  ----  ------  -----------   -----------------------------------------
0       4     uint32  id            OSM user ID (little-endian)
4       2     uint16  name_length   Byte length of the display name string (N)
6       N     bytes   name          UTF-8 display name
```

Total size: `6 + name.length()`

```cpp
// datatypes.h:448–453
void to_data(void* data) const {
  *(uint32*)data              = id;
  *(uint16*)((int8*)data + 4) = name.length();
  memcpy((int8*)data + 6, name.data(), name.length());
}

// from_data constructor  (datatypes.h:432–435)
id   = *(uint32*)data;
name = std::string(((int8*)data + 6), *(uint16*)((int8*)data + 4));
```

**Index key:** `Uint32_Index(user_id & 0xFFFFFF00)` — users are grouped in blocks of 256 (`meta_updater.cc:48, 56`).

**Ordering** (`operator<`): by `id` ascending.

---

### `Uint31_Index` — user index record

**Source:** `src/overpass_api/core/basic_types.h:120–163`

`user_indices.bin` stores, for each user ID, the set of **compressed spatial tiles** they have edited. The value type is `Uint31_Index` — a plain 4-byte little-endian `uint32`.

```
Offset  Size  Type    Field   Description
------  ----  ------  ------  --------------------------------------------------
0       4     uint32  idx     Compressed spatial index of an edited element tile
```

**Index key compression** (`meta_updater.h:144–146`):
- Normal tile: stored as `index & 0xFFFFFF00` (coarse 24-bit prefix)
- Geometry tile (multi-tile way/relation, MSB set, bit 1 clear): stored as the full `index` value

```cpp
// meta_updater.h:144–146
uint32 compressed_idx = (it->first.val() & 0xffffff00);
if ((it->first.val() & 0x80000000) && ((it->first.val() & 0x3) == 0))
  compressed_idx = it->first.val();
```

**Index key** for `user_indices.bin`: the user ID itself, stored as `Uint32_Index(user_id)`.

---

### `Timestamp` — changelog index key

**Source:** `src/overpass_api/core/datatypes.h:623–732`

`Timestamp` appears as the **index key** type in the changelog files (`node_changelog.bin`, `way_changelog.bin`, `relation_changelog.bin`). It is serialised as the same 5-byte packed datetime described above. Because `size_of()` returns 5 and `const_size()` also returns 5, it is a fixed-size index key.

```cpp
uint32 size_of() const { return 5; }
static constexpr uint32 const_size() { return 5; }
```

The changelog files are not part of the `--meta=yes` set but do appear under `--meta=attic` (see `nodes-bin-format.md` documentation status list).

---

## Logical Structure

```
nodes_meta.bin / ways_meta.bin / relations_meta.bin
  Index key:  spatial tile (same quadtile as the corresponding .bin file)
  Value:      OSM_Element_Metadata_Skeleton (25 B for nodes, 21 B for ways/relations)
  Use:  "what is the version / changeset / user for element X in tile T?"
        → range-query the same tile ranges used to find the element skeleton

user_data.bin
  Index key:  user_id & 0xFFFFFF00  (block of 256 users)
  Value:      User_Data  (4-byte id + 2-byte length + UTF-8 name)
  Use:  "what is the display name for user_id U?"
        → look up block for (U & 0xFFFFFF00), scan for record with id == U

user_indices.bin
  Index key:  user_id (exact)
  Value:      set of Uint31_Index (compressed tile IDs)
  Use:  "which tiles has user U edited?"
        → discrete lookup by user_id, returns set of compressed tile indices
        (can be used to scope queries to a user's edits)
```

---

## Visual Layouts

### Meta file block payload (nodes_meta.bin)

```
(decompressed block buffer — nodes_meta.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size   (uint32)                              │
│                                                                      │
│  ── Index Group: Uint32_Index (spatial tile) ───────────────────── ─ │
│  [4..7]   next_idx_offset      (uint32, byte offset of next group)   │
│  [8..11]  index_key            (uint32, Uint32_Index tile value)     │
│  ── value records (OSM_Element_Metadata_Skeleton<Uint64>) ─────────  │
│  Per record (25 bytes, one per node in this tile):                   │
│    [+0..+7]   ref              (uint64 LE, node ID)                  │
│    [+8..+11]  version          (uint32 LE)                           │
│    [+12..+16] timestamp        (40-bit LE packed datetime, 5 bytes)  │
│    [+17..+20] changeset        (uint32 LE)                           │
│    [+21..+24] user_id          (uint32 LE)                           │
│                                                                      │
│  ── Index Group 2 (starts at next_idx_offset) ─────────────────────  │
│  ...                                                                 │
│  [total_payload_size .. block_size-1]  zero padding                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Meta file block payload (ways_meta.bin / relations_meta.bin)

```
(decompressed block buffer — ways_meta.bin or relations_meta.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size   (uint32)                              │
│                                                                      │
│  ── Index Group: Uint31_Index (spatial tile) ───────────────────── ─ │
│  [4..7]   next_idx_offset      (uint32)                              │
│  [8..11]  index_key            (uint32, Uint31_Index tile value)     │
│  ── value records (OSM_Element_Metadata_Skeleton<Uint32_Index>) ───  │
│  Per record (21 bytes, one per way/relation in this tile):           │
│    [+0..+3]   ref              (uint32 LE, way/relation ID)          │
│    [+4..+7]   version          (uint32 LE)                           │
│    [+8..+12]  timestamp        (40-bit LE packed datetime, 5 bytes)  │
│    [+13..+16] changeset        (uint32 LE)                           │
│    [+17..+20] user_id          (uint32 LE)                           │
│                                                                      │
│  ── Index Group 2 ──────────────────────────────────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

### user_data.bin block payload

```
(decompressed block buffer — user_data.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size   (uint32)                              │
│                                                                      │
│  ── Index Group: Uint32_Index (user_id & 0xFFFFFF00) ─────────────── │
│  [4..7]   next_idx_offset      (uint32)                              │
│  [8..11]  index_key            (uint32, user_id & 0xFFFFFF00)        │
│  ── value records (User_Data) ─────────────────────────────────────  │
│  Per record (variable length):                                       │
│    [+0..+3]   id               (uint32 LE, exact user ID)            │
│    [+4..+5]   name_length      (uint16 LE, byte length of name N)    │
│    [+6..+6+N-1] name           (UTF-8 display name, N bytes)         │
│                                                                      │
│  ── Index Group 2 (next block of 256 user IDs) ────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

### user_indices.bin block payload

```
(decompressed block buffer — user_indices.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size   (uint32)                              │
│                                                                      │
│  ── Index Group: Uint32_Index (exact user_id) ─────────────────────  │
│  [4..7]   next_idx_offset      (uint32)                              │
│  [8..11]  index_key            (uint32, user_id)                     │
│  ── value records (Uint31_Index, 4 bytes each) ─────────────────────  │
│    [+0..+3]  compressed_idx    (uint32 LE, edited spatial tile)      │
│    [+4..+7]  compressed_idx    ...                                   │
│    ...       (one per distinct tile this user has edited)            │
│                                                                      │
│  ── Index Group 2 (next user) ──────────────────────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Read/Write Pseudocode

### Reading metadata for a set of elements

```
function read_meta(meta_file, tile_ranges):
    # tile_ranges: same range set used to query the corresponding .bin file
    results = {}   # map element_id -> OSM_Element_Metadata_Skeleton

    for (tile_idx, meta_rec) in block_backend.range_iterate(meta_file, tile_ranges):
        results[meta_rec.ref] = meta_rec
        # meta_rec.ref      = element ID
        # meta_rec.version  = version number
        # meta_rec.timestamp = 40-bit packed datetime
        # meta_rec.changeset = changeset ID
        # meta_rec.user_id  = user ID (resolve name via user_data.bin lookup)

    return results
```

### Resolving a user name

```
function lookup_user_name(user_data_file, user_id):
    block_key = Uint32_Index(user_id & 0xFFFFFF00)
    for user_rec in block_backend.discrete_iterate(user_data_file, {block_key}):
        if user_rec.id == user_id:
            return user_rec.name
    return ""   # user not found
```

### Writing metadata (update path)

```
function update_meta(meta_file, user_data_file, user_indices_file,
                     old_elements, new_elements_with_meta):
    meta_to_delete = {}   # map tile_idx -> set<OSM_Element_Metadata_Skeleton>
    meta_to_insert = {}   # map tile_idx -> set<OSM_Element_Metadata_Skeleton>
    user_by_id     = {}   # map user_id -> display_name
    idxs_by_user   = {}   # map user_id -> list<compressed_idx>

    # Stage deletions of old metadata (at old spatial positions)
    for (old_tile, old_meta) in old_elements:
        meta_to_delete[old_tile].add(old_meta)

    # Stage insertions of new metadata
    for (new_tile, new_meta) in new_elements_with_meta:
        meta_to_insert[new_tile].add(new_meta)
        user_by_id[new_meta.user_id]  = new_meta.user_name   # from OSM input
        compressed = new_tile & 0xFFFFFF00
        if (new_tile & 0x80000000) and (new_tile & 0x3 == 0):
            compressed = new_tile   # geometry tile: keep full value
        idxs_by_user[new_meta.user_id].append(compressed)

    # Write metadata records (keyed by spatial tile, same as skeleton files)
    block_backend.update(meta_file, meta_to_delete, meta_to_insert)

    # Update user name mapping (keyed by user_id & 0xFFFFFF00)
    user_data_to_delete = {}
    user_data_to_insert = {}
    for (uid, name) in user_by_id:
        block_key = Uint32_Index(uid & 0xFFFFFF00)
        user_data_to_delete[block_key].add(User_Data(id=uid))   # delete by id
        user_data_to_insert[block_key].add(User_Data(id=uid, name=name))
    block_backend.update(user_data_file, user_data_to_delete, user_data_to_insert)

    # Update user → tile-set index (keyed by exact user_id)
    user_idx_to_delete = {}
    user_idx_to_insert = {}
    for (uid, tiles) in idxs_by_user:
        for compressed in tiles:
            user_idx_to_delete[Uint32_Index(uid)].add(Uint31_Index(compressed))
            user_idx_to_insert[Uint32_Index(uid)].add(Uint31_Index(compressed))
    block_backend.update(user_indices_file, user_idx_to_delete, user_idx_to_insert)
```

### Decoding a 40-bit timestamp

```
function decode_timestamp(ts):
    year   = (ts >> 26) & 0x3FFF
    month  = (ts >> 22) & 0xF
    day    = (ts >> 17) & 0x1F
    hour   = (ts >> 12) & 0x1F
    minute = (ts >>  6) & 0x3F
    second = (ts >>  0) & 0x3F
    return "{:04d}-{:02d}-{:02d}T{:02d}:{:02d}:{:02d}Z".format(
           year, month, day, hour, minute, second)
```

---

## Source File Reference

| Component | File | Lines |
|-----------|------|-------|
| `OSM_Element_Metadata_Skeleton<Id_Type>` | `src/overpass_api/core/datatypes.h` | 481–547 |
| `OSM_Element_Metadata` (in-memory struct) | `src/overpass_api/core/datatypes.h` | 467–478 |
| `User_Data` | `src/overpass_api/core/datatypes.h` | 423–464 |
| `Timestamp` struct (40-bit packed datetime) | `src/overpass_api/core/datatypes.h` | 623–732 |
| `Meta_Settings` constructor (file properties) | `src/overpass_api/core/settings.cc` | 223–237 |
| Attic meta file properties | `src/overpass_api/core/settings.cc` | 268–303 |
| `process_user_data()` — user file update | `src/overpass_api/osm-backend/meta_updater.cc` | 36–89 |
| `copy_idxs_by_id()` — user index accumulation | `src/overpass_api/osm-backend/meta_updater.h` | 137–150 |
| `collect_old_meta_data()` — deletion read | `src/overpass_api/osm-backend/meta_updater.h` | 157–220 |
| `current_meta_file_properties<>()` | `src/overpass_api/data/filenames.h` | 44–57 |
| `attic_meta_file_properties<>()` | `src/overpass_api/data/filenames.h` | 203–216 |
| `Meta_Collector` (read-side API) | `src/overpass_api/data/meta_collector.h` | — |
| Block backend (container layer) | `src/template_db/block_backend.h` | — |
