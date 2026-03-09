# Query Processing: Hypothetical Strategies vs. Actual Implementation

This document compares hypothetical query execution strategies (derived from the file format
documentation) against the actual implementation. The goal is to understand how query statements
map to file I/O operations, and to identify any discrepancies or surprises.

---

## 1. Simple Tag Filter: `node["key"="value"]`

### Query semantics

Returns every node in the database where a specific tag key is set to a specific value.
No spatial constraint is implied — the result set may span the entire world.

### Files involved

| File | Role |
|------|------|
| `node_tags_global.bin` / `.idx` | Primary lookup: maps `(key, value)` → `(spatial_tile, node_id)` |
| `nodes.bin` / `.bin.idx` | Secondary fetch: maps `spatial_tile` → `Node_Skeleton` (coordinates) |

### Hypothetical execution strategy

#### Step 1 — Query the global tag index

`node_tags_global.bin` is keyed by `Tag_Index_Global_KVI`, which sorts by `(key, value, idx)`.
All entries for a given `(key, value)` pair form a contiguous range regardless of the `idx`
(spatial split) field.

Construct a range query:

```
lo = Tag_Index_Global_KVI(key=key, value=value,        idx=0)
hi = Tag_Index_Global_KVI(key=key, value=value + '\0', idx=0)
```

Iterate over `node_tags_global.bin` within `[lo, hi)`. Each result record is a
`Tag_Object_Global<Uint64>`, which encodes:

- `idx` — coarse spatial tile of the node (`Uint31_Index.val() >> 8`, stored as 3 bytes)
- `id`  — OSM node ID (8-byte `Uint64`)

Collect all `(coarse_tile, node_id)` pairs.

**Note on the KVI split:** For very common tags (e.g. `amenity=yes`), the global file shards
objects across multiple `Tag_Index_Global_KVI` entries using different `idx` values (at level 8,
16, or 24 bits of spatial prefix). The range `[lo, hi)` above covers all shards because
`value + '\0'` sorts after any `idx` value for `value`, so no extra logic is needed to handle
the split levels at read time.

#### Step 2 — Collect distinct spatial tiles

Group the results from Step 1 by their coarse spatial tile. The coarse tile recovered from
`Tag_Object_Global` is `(Uint31_Index.val() >> 8) << 8` — i.e. the tile with the lower 8 bits
zeroed. The full `Uint31_Index` tile needed to query `nodes.bin` may include those lower 8 bits,
but the block backend's range iterate accepts coarse ranges, so fetching all blocks covered by
each coarse tile prefix is sufficient.

#### Step 3 — Fetch skeleton records from `nodes.bin`

Perform a discrete (set-of-tiles) iteration over `nodes.bin` using the collected tile set.
Each block yields `Node_Skeleton` records:

- `id`       — OSM node ID (8-byte `Uint64`)
- `ll_lower` — lower 32 bits of the Morton-code coordinate

The spatial tile index key for the block provides `ll_upper` (upper 32 bits). Together,
`ll_upper` and `ll_lower` give the full 64-bit quadtile coordinate, from which latitude and
longitude can be recovered.

Filter each skeleton against the node ID set obtained in Step 1 to discard unrelated nodes
that happen to share the same tile.

#### Step 4 — Output

Each matched node is now represented as:

- OSM node ID (from `id`)
- Latitude / longitude (decoded from `ll_upper || ll_lower`)
- Tags — available from the global tag index itself (key and value are encoded in the index key)
  for the single tag matched, but a full tag set requires a secondary lookup in
  `node_tags_local.bin` (see note below)

**Tag completeness note:** The global tag file stores only one `(key, value)` pair per index
entry. To return the full tag set for each matched node (as `out body` requires), an additional
range query over `node_tags_local.bin` would be needed for each tile, using
`Tag_Index_Local(coarse_tile, *, *)` ranges to retrieve all tags for nodes in those tiles.

---

### Variation: with a global bounding box (`[bbox:…] node["key"="value"]`)

When a bounding box is present, the local tag index becomes more efficient than the global one
for tags of moderate frequency, because it is already partitioned by spatial tile.

#### Alternative Step 1 — Query the local tag index

Convert the bounding box corners to a set of `Uint31_Index` coarse tile ranges using the
Morton-code scheme (`ll_upper` computation). For each coarse tile in the range, construct:

```
lo = Tag_Index_Local(index=tile,        key=key,   value=value)
hi = Tag_Index_Local(index=tile + 0x100, key=key,  value=value + '\0')
```

Iterate over `node_tags_local.bin` within those ranges. Each result record is a `Uint64` node ID.
The coarse tile of the node is already known from the index key.

This avoids reading the global file entirely and returns node IDs pre-filtered to the spatial
region of interest.

#### Remaining steps

Steps 2–4 are the same as the unbounded case, but the tile set is already bounded by the
bounding box, so Step 3 reads far fewer blocks from `nodes.bin`.

---

### Open questions for comparison against actual implementation

1. Does the actual implementation always use the global file for unbounded tag queries, or does
   it use a full-scan strategy for very common tags?
2. How does the actual implementation resolve the coarse tile (3 bytes, lower byte zeroed) from
   `Tag_Object_Global` back to the full `Uint31_Index` needed to query `nodes.bin`?
3. Is the secondary `node_tags_local.bin` read actually performed for `out body`, or are tags
   cached/carried differently?
4. For the bounded case, at what tag-frequency threshold does the implementation switch between
   the local and global index?
