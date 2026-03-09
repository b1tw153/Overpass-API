# OSM Binary File Formats: Attic Administrative Files and String Tables

## Overview

This document covers two groups of files that sit alongside the element skeleton and tag files:

**Attic administrative files** (present only when `--meta=attic` is active) — three families of support files that track historical element positions, re-creations, and change events:

| File | Index key | Value type | Purpose |
|------|-----------|------------|---------|
| `node_attic_indexes.bin` | `Uint64` (node ID) | `Uint32_Index` (tile) | Historical tile set for multi-position nodes |
| `way_attic_indexes.bin` | `Uint32_Index` (way ID) | `Uint31_Index` (tile) | Historical tile set for multi-position ways |
| `relation_attic_indexes.bin` | `Uint32_Index` (relation ID) | `Uint31_Index` (tile) | Historical tile set for multi-position relations |
| `nodes_attic_undeleted.bin` | `Uint32_Index` (tile) | `Attic<Uint64>` | Nodes recreated at a previously-held tile |
| `ways_attic_undeleted.bin` | `Uint31_Index` (tile) | `Attic<Uint32_Index>` | Ways recreated at a previously-held tile |
| `relations_attic_undeleted.bin` | `Uint31_Index` (tile) | `Attic<Uint32_Index>` | Relations recreated at a previously-held tile |
| `node_changelog.bin` | `Timestamp` (5 bytes) | `Uint64` (node ID) | Which nodes changed at each timestamp |
| `way_changelog.bin` | `Timestamp` (5 bytes) | `Uint32_Index` (way ID) | Which ways changed at each timestamp |
| `relation_changelog.bin` | `Timestamp` (5 bytes) | `Uint32_Index` (relation ID) | Which relations changed at each timestamp |

**String table files** (present for all databases, in the base file set) — compact enumerations of all unique tag key strings and relation role strings:

| File | Index key | Value type | Purpose |
|------|-----------|------------|---------|
| `node_keys.bin` | `Uint32_Index` (key ID) | `String_Object` | All tag keys used on nodes |
| `way_keys.bin` | `Uint32_Index` (key ID) | `String_Object` | All tag keys used on ways |
| `relation_keys.bin` | `Uint32_Index` (key ID) | `String_Object` | All tag keys used on relations |
| `relation_roles.bin` | `Uint32_Index` (role ID) | `String_Object` | All role strings used in relations |

All files use the Block Backend container format described in `nodes-bin-format.md`.

---

## File Properties

### Attic administrative files (Attic_Settings, `src/overpass_api/core/settings.cc:254–319`)

| File | Settings line | Index type | Block size param | Physical block | Map block |
|------|--------------|------------|-----------------|----------------|-----------|
| `nodes_attic_undeleted` | 257 | `Node::Index` | 128 KiB | 16 KiB | 8 KiB |
| `node_attic_indexes` | 258 | `Node::Id_Type` | 128 KiB | 16 KiB | — |
| `node_changelog` | 270 | `Timestamp` | 128 KiB | 16 KiB | — |
| `ways_attic_undeleted` | 274 | `Way::Index` | 128 KiB | 16 KiB | 8 KiB |
| `way_attic_indexes` | 275 | `Way::Id_Type` | 128 KiB | 16 KiB | — |
| `way_changelog` | 287 | `Timestamp` | 128 KiB | 16 KiB | — |
| `relations_attic_undeleted` | 291 | `Relation::Index` | 128 KiB | 16 KiB | 8 KiB |
| `relation_attic_indexes` | 292 | `Relation::Id_Type` | 128 KiB | 16 KiB | — |
| `relation_changelog` | 304 | `Timestamp` | 128 KiB | 16 KiB | — |

The three `*_attic_undeleted` files have a companion `.map` file (map block size = 64 KiB / 8 = 8 KiB physical). All other files have no `.map`.

### String table files (OSM_Base_Settings, `src/overpass_api/core/settings.cc:125–174`)

| File | Settings line | Index type | Block size param | Physical block |
|------|--------------|------------|-----------------|----------------|
| `node_keys` | 132 | `Uint32_Index` | 512 KiB | 64 KiB |
| `way_keys` | 144 | `Uint32_Index` | 512 KiB | 64 KiB |
| `relation_keys` | 158 | `Uint32_Index` | 512 KiB | 64 KiB |
| `relation_roles` | 150 | `Uint32_Index` | 512 KiB | 64 KiB |

---

## Record Formats

### `String_Object` — string table value

**Source:** `src/overpass_api/core/datatypes.h:40–84`

Used as the value type in all four string table files. A length-prefixed UTF-8 string.

```
Offset  Size  Type    Field   Description
------  ----  ------  ------  ------------------------------------
0       2     uint16  length  Byte length of the string (N)
2       N     bytes   value   UTF-8 string content
```

Total size: `2 + length`

```cpp
// to_data  (datatypes.h:61–65)
*(uint16*)data = value.length();
memcpy((uint8*)data + 2, value.data(), value.length());

// from_data constructor  (datatypes.h:46–49)
value = std::string(((int8*)data + 2), *(uint16*)data);
```

**Ordering** (`operator<`): lexicographic on `value`. Within an index group all strings sort alphabetically.

---

### `Uint32_Index` / `Uint31_Index` / `Uint64` — spatial tile and ID values

These types appear both as index keys and as values in the attic index list and changelog files. Their serialisation is documented in `nodes-bin-format.md`. Sizes: `Uint32_Index` = 4 bytes, `Uint31_Index` = 4 bytes, `Uint64` = 8 bytes.

---

### `Attic<Id_Type>` — timestamped ID (undeleted file value)

**Source:** `src/overpass_api/core/basic_types.h:242–284`

Wraps an element ID with a 5-byte timestamp. The same `Attic<>` wrapper used in attic skeleton files.

For nodes — `Attic<Uint64>`, total **13 bytes**:

```
Offset  Size  Type    Field          Description
------  ----  ------  ----------     -----------------------------------------
0       8     uint64  id             OSM node ID (little-endian)
8       4     uint32  timestamp_low  Lower 32 bits of 40-bit packed timestamp
12      1     uint8   timestamp_hi   Bits 32–39 of 40-bit packed timestamp
```

For ways / relations — `Attic<Uint32_Index>`, total **9 bytes**:

```
Offset  Size  Type    Field          Description
------  ----  ------  ----------     -----------------------------------------
0       4     uint32  id             OSM way / relation ID (little-endian)
4       4     uint32  timestamp_low  Lower 32 bits of 40-bit packed timestamp
8       1     uint8   timestamp_hi   Bits 32–39 of 40-bit packed timestamp
```

The 40-bit timestamp encoding is described in `meta-format.md § Timestamp Encoding`.

---

### `Change_Entry<Id_Type>` — legacy changelog value (version ≤ 7561)

**Source:** `src/overpass_api/core/datatypes.h:571–620`

The changelog files before version 7562 stored a `Change_Entry` per element change, encoding both the old and new tile. This format is still readable by the code (`dump_file.cc:253–259`) but is no longer written.

For nodes — `Change_Entry<Uint64>`, total **16 bytes**:

```
Offset  Size  Type    Field     Description
------  ----  ------  --------  ---------------------------------------------------
0       4     uint32  old_idx   Old spatial tile (Uint31_Index, little-endian)
4       4     uint32  new_idx   New spatial tile (Uint31_Index, little-endian)
8       8     uint64  elem_id   OSM node ID (little-endian)
```

For ways / relations — `Change_Entry<Uint32_Index>`, total **12 bytes**:

```
Offset  Size  Type    Field     Description
------  ----  ------  --------  ---------------------------------------------------
0       4     uint32  old_idx   Old spatial tile (Uint31_Index, little-endian)
4       4     uint32  new_idx   New spatial tile (Uint31_Index, little-endian)
8       4     uint32  elem_id   OSM way / relation ID (little-endian)
```

```cpp
// to_data  (datatypes.h:596–601)
old_idx.to_data((uint8*)data);
new_idx.to_data((uint8*)data + 4);
elem_id.to_data((uint8*)data + 8);
```

---

## Attic Index List Files (`*_attic_indexes.bin`)

**Source:** `src/overpass_api/osm-backend/basic_updater.h:500–530`

```
Block_Backend< Node_Skeleton::Id_Type, Uint31_Index >  — nodes
Block_Backend< Way_Skeleton::Id_Type,  Uint31_Index >  — ways
Block_Backend< Relation_Skeleton::Id_Type, Uint31_Index >  — relations
```

### Purpose

The `.map` file for each element type stores only a **single** current tile per element ID. When an element has moved across tiles during its lifetime, its full set of historical tile positions would be lost. The attic index list file fills this gap: for every element that has ever appeared at more than one tile, this file stores the complete set of tiles where it has been seen.

Elements that have spent their entire history at a single tile are **not stored here** — their single-tile history is implicit in the `.map` file.

### Layout within the file

The index key is the element ID (`Uint64` for nodes, `Uint32_Index` for ways/relations). The values are the set of `Uint31_Index` tiles. An element's block contains one 4-byte tile value per historical position.

```
Index key:  element_id (8 B for nodes, 4 B for ways/relations)
Values:     one Uint31_Index (4 B) per historical tile, in ascending order
```

### Usage

`get_existing_idx_lists()` (`basic_updater.h:500–530`) reads this file to reconstruct the full historical position set before an update. After the update, `update_elements(existing_idx_lists, new_attic_idx_lists, ...)` rewrites only the entries that changed.

The sentinel value `Uint31_Index(0xff)` (= 255) in the companion `.map` file indicates that an element has entries in the index list file and cannot be represented by a single tile (`strip_single_idxs()`, `basic_updater.h:534–555`).

---

## Undeleted Files (`*_attic_undeleted.bin`)

**Source:** `src/overpass_api/osm-backend/node_updater.cc:157–195`

```
Block_Backend< Uint32_Index,  Attic< Uint64 > >         — nodes
Block_Backend< Uint31_Index,  Attic< Uint32_Index > >   — ways / relations
```

### Purpose

Records element versions that were created (or re-created) **at a tile where the same element ID had previously been present in the attic**. This distinguishes a genuine re-creation from an ordinary element-at-new-tile situation.

Concretely: if node ID 12345 was deleted at tile T in an earlier update, and a later update creates node 12345 at tile T again, the undeleted file records `(tile=T, id=12345, timestamp=recreation_time)`. At query time, this entry indicates that the element was absent from tile T in the gap between deletion and recreation.

The index key is the tile; the value is the `Attic<Id_Type>` (element ID + timestamp of the re-creation).

### Usage

`compute_undeleted_skeletons()` (`node_updater.cc:157–195`) generates the set of entries. `get_existing_attic_skeleton_timestamps()` (`basic_updater.h:179–237`) reads this file alongside the main attic skeleton file to reconstruct the complete version timeline for elements being updated.

---

## Changelog Files (`*_changelog.bin`)

**Source:** `src/overpass_api/osm-backend/node_updater.cc:400–445`

```
Block_Backend< Timestamp, Node_Skeleton::Id_Type >      — nodes (current)
Block_Backend< Timestamp, Way_Skeleton::Id_Type >       — ways (current)
Block_Backend< Timestamp, Relation_Skeleton::Id_Type >  — relations (current)
```

### Purpose

Records, for each point in time at which elements were modified, **which element IDs changed**. This file drives temporal queries: to answer "what elements changed between time T1 and T2?" the query engine range-scans the changelog by `Timestamp` index key.

### Current format (version ≥ 7562)

Index key: `Timestamp` (5-byte packed datetime, see `meta-format.md`).
Value: element ID (`Uint64` = 8 bytes for nodes, `Uint32_Index` = 4 bytes for ways/relations).

Multiple values can share the same timestamp index key — all elements modified in the same batch are stored under the same key. The block backend's index-group structure naturally groups all IDs for a given timestamp together.

### Legacy format (version ≤ 7561)

Index key: same `Timestamp` (5 bytes).
Value: `Change_Entry<Id_Type>` (16 bytes for nodes, 12 bytes for ways/relations), which additionally stored the old and new tile for each change. This format was superseded at version 7562 and is read-only (`dump_file.cc:253–259`).

The migration from version ≤ 7561 is handled by `migrate_database.cc:70–72, 131–135`.

---

## String Table Files

### `relation_roles.bin` — relation role strings

**Source:** `src/overpass_api/osm-backend/relation_updater.cc` (load/flush logic)

```
Block_Backend< Uint32_Index, String_Object >
```

Maps a numeric **role ID** to the corresponding UTF-8 role string. The role ID is the value stored in the `role` field of every `Relation_Entry` in the skeleton files:

```cpp
// Relation_Entry serialisation (type_relation.h)
*((uint32*)data + 6 + 3*i) = members[i].role & 0xffffff;  // 24-bit role ID
```

To decode a relation member's role, look up `role_id` in this file and read the `String_Object` value. Role IDs are assigned sequentially (0, 1, 2, …) as new role strings appear in input data.

**Index key:** `Uint32_Index(role_id)` — the numeric role ID.
**Value:** `String_Object` — the UTF-8 role string (e.g., `"outer"`, `"inner"`, `""`, `"stop"`).

### `node_keys.bin` / `way_keys.bin` / `relation_keys.bin` — tag key strings

**Source:** `src/overpass_api/osm-backend/basic_updater.cc:30–70` (`Key_Storage`)

```
Block_Backend< Uint32_Index, String_Object >
```

Stores the set of all unique tag key strings that have appeared for each element type, with sequential integer IDs. Key IDs are assigned in the order keys are first encountered (`Key_Storage::register_key()`).

**Index key:** `Uint32_Index(key_id)` — the sequential key ID.
**Value:** `String_Object` — the UTF-8 tag key string (e.g., `"name"`, `"highway"`, `"building"`).

Unlike `relation_roles.bin`, key IDs are **not stored in the tag index files** — those files store key strings directly. The key files serve as a compact enumeration of all distinct tag keys for a given element type, allowing the query engine to enumerate or validate keys without scanning the full tag data.

---

## Visual Layouts

### Attic index list file block payload

```
(decompressed block buffer — node_attic_indexes.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: Uint64 (node ID) ─────────────────────────────── ─ │
│  [4..7]   next_idx_offset     (uint32)                               │
│  [8..15]  index_key           (uint64 LE, node ID)                   │
│  ── value records (Uint31_Index tile positions) ───────────────────  │
│    [+0..+3]  tile_1           (uint32 LE, Uint31_Index)              │
│    [+4..+7]  tile_2           (uint32 LE, Uint31_Index)              │
│    ...       (one per historical tile, ascending order)              │
│                                                                      │
│  ── Index Group 2 (next node ID) ──────────────────────────────────  │
│  ...                                                                 │
│  [total_payload_size .. block_size-1]  zero padding                  │
└──────────────────────────────────────────────────────────────────────┘

(way_attic_indexes.bin / relation_attic_indexes.bin: same layout but
 index key is uint32 way/relation ID instead of uint64)
```

### Undeleted file block payload

```
(decompressed block buffer — nodes_attic_undeleted.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: Uint32_Index (spatial tile) ───────────────────── ─ │
│  [4..7]   next_idx_offset     (uint32)                               │
│  [8..11]  index_key           (uint32 LE, tile)                      │
│  ── value records (Attic<Uint64>) ─────────────────────────────────  │
│  Per record (13 bytes, one per recreated node at this tile):         │
│    [+0..+7]   id              (uint64 LE, node ID)                   │
│    [+8..+11]  timestamp_low   (uint32 LE, lower 32 bits of ts)       │
│    [+12]      timestamp_hi    (uint8, bits 32-39 of timestamp)       │
│                                                                      │
│  ── Index Group 2 ──────────────────────────────────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘

(ways/relations: same layout; index key is Uint31_Index, values are
 Attic<Uint32_Index> = 9 bytes per record)
```

### Changelog file block payload

```
(decompressed block buffer — node_changelog.bin, current format ≥ 7562)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: Timestamp (5 bytes, fixed-size key) ────────────── │
│  [4..7]   next_idx_offset     (uint32)                               │
│  [8..12]  index_key           (5-byte LE packed datetime)            │
│  ── value records (Node_Skeleton::Id_Type = Uint64) ───────────────  │
│    [+0..+7]   node_id         (uint64 LE, node that changed)         │
│    [+8..+15]  node_id         (uint64 LE, next node that changed)    │
│    ...        (all nodes modified in this batch)                     │
│                                                                      │
│  ── Index Group 2 (next timestamp) ─────────────────────────────── │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘

(way/relation changelog: same layout but id values are uint32;
 legacy format ≤ 7561: values are Change_Entry<Id_Type> =
 old_idx(4) + new_idx(4) + id(8 or 4) per record)
```

### String table file block payload

```
(decompressed block buffer — relation_roles.bin or *_keys.bin)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: Uint32_Index (role/key ID) ────────────────────── ─ │
│  [4..7]   next_idx_offset     (uint32)                               │
│  [8..11]  index_key           (uint32 LE, sequential ID)             │
│  ── single value record (String_Object) ───────────────────────────  │
│    [+0..+1]  length           (uint16 LE, byte length of string N)   │
│    [+2..+2+N-1] value         (UTF-8 string, N bytes)                │
│                                                                      │
│  ── Index Group 2 (next ID / next string) ─────────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Read/Write Pseudocode

### Reading all historical tile positions for an element

```
function get_all_historical_tiles(idx_list_file, map_file, element_id):
    # Step 1: check the .map file for the current/single tile
    current_tile = random_file.get(element_id)
    if current_tile == 0:
        return set()   # element not known

    # Step 2: if current_tile == 0xff, the idx_list file has multiple entries
    if current_tile == 0xff:
        tiles = set()
        for tile in block_backend.discrete_iterate(idx_list_file, {element_id}):
            tiles.add(tile)
        return tiles
    else:
        return {current_tile}
```

### Reading the changelog for a time range

```
function read_changelog(changelog_file, t_start, t_end):
    lo = Timestamp(t_start)
    hi = Timestamp(t_end)
    changed_ids = []
    for (ts, elem_id) in block_backend.range_iterate(changelog_file, [[lo, hi))):
        changed_ids.append((ts, elem_id))
    return changed_ids
    # ts is a 40-bit packed datetime; elem_id is Uint64 (nodes) or Uint32_Index (ways/relations)
```

### Looking up a relation role string

```
function get_role_string(roles_file, role_id):
    # role_id comes from Relation_Entry.role (24-bit field in skeleton)
    for str_obj in block_backend.discrete_iterate(roles_file, {Uint32_Index(role_id)}):
        return str_obj.value   # UTF-8 role string
    return ""   # role_id not found (should not happen in valid data)
```

### Writing string tables (key/role registration)

```
function flush_keys_or_roles(file, key_ids):
    # key_ids: map string -> uint32  (built incrementally as new keys are encountered)
    # Only write entries for IDs >= max_written_key_id (newly registered keys)
    to_insert = {}
    for (string, id) in key_ids:
        if id >= max_written_key_id:
            to_insert[Uint32_Index(id)].add(String_Object(string))
    block_backend.update(file, {}, to_insert)
    max_written_key_id = max_key_id

function register_key(key_ids, s):
    if s not in key_ids:
        key_ids[s] = max_key_id
        max_key_id += 1
```

### Writing attic index lists (after an element moves)

```
function update_idx_lists(idx_list_file, map_file, element_id, all_historical_tiles):
    if len(all_historical_tiles) == 1:
        # Store directly in .map; no idx_list entry needed
        random_file.put(element_id, single_tile)
        block_backend.update(idx_list_file, {element_id: all_old_tiles}, {})
    else:
        # Store sentinel in .map; full set in idx_list
        random_file.put(element_id, Uint31_Index(0xff))
        block_backend.update(idx_list_file,
                             {element_id: old_tiles},
                             {element_id: all_historical_tiles})
```

---

## Source File Reference

| Component | File | Lines |
|-----------|------|-------|
| `String_Object` struct | `src/overpass_api/core/datatypes.h` | 40–84 |
| `Change_Entry<Id_Type>` struct (legacy changelog) | `src/overpass_api/core/datatypes.h` | 571–620 |
| `Timestamp` struct | `src/overpass_api/core/datatypes.h` | 623–732 |
| `Attic<>` wrapper | `src/overpass_api/core/basic_types.h` | 242–284 |
| `Attic_Settings` constructor (all attic file properties) | `src/overpass_api/core/settings.cc` | 254–319 |
| `OSM_Base_Settings` constructor (key/role file properties) | `src/overpass_api/core/settings.cc` | 125–174 |
| `get_existing_idx_lists()` | `src/overpass_api/osm-backend/basic_updater.h` | 500–530 |
| `strip_single_idxs()` | `src/overpass_api/osm-backend/basic_updater.h` | 534–555 |
| `compute_undeleted_skeletons()` | `src/overpass_api/osm-backend/node_updater.cc` | 157–195 |
| `compute_changelog()` (nodes) | `src/overpass_api/osm-backend/node_updater.cc` | 400–445 |
| `compute_changelog()` (ways) | `src/overpass_api/osm-backend/way_updater.cc` | 687+ |
| `compute_changelog()` (relations) | `src/overpass_api/osm-backend/relation_updater.cc` | 948+ |
| Node attic update (writes all attic admin files) | `src/overpass_api/osm-backend/node_updater.cc` | 580–664 |
| `Key_Storage::load_keys()` | `src/overpass_api/osm-backend/basic_updater.cc` | 49–60 |
| `Key_Storage::flush_keys()` | `src/overpass_api/osm-backend/basic_updater.cc` | 30–46 |
| `Key_Storage::register_key()` | `src/overpass_api/osm-backend/basic_updater.cc` | 63–70 |
| Changelog format version check | `src/overpass_api/osm-backend/dump_file.cc` | 250–267 |
| Changelog migration trigger | `src/overpass_api/osm-backend/migrate_database.cc` | 70–72, 131–135 |
| Role read/write | `src/overpass_api/osm-backend/relation_updater.cc` | 50–81, 1340–1372 |
| Block backend (container layer) | `src/template_db/block_backend.h` | — |
