extends RefCounted
## Per-track intervals ordered by start. Subtree end maxima let a window skip
## offscreen steps even when a long clip overlaps many short ones.

const MIN_BLOCK_WIDTH := 10.0

var _tracks := {}

func rebuild(timeline: Array, pixels_per_unit: float, ruler_x: float) -> void:
	_tracks.clear()
	for i in timeline.size():
		var entry: Dictionary = timeline[i]
		if entry.is_empty():
			continue
		var track := int(entry.track)
		if not _tracks.has(track):
			_tracks[track] = []
		_tracks[track].append(i)
	for track in _tracks:
		var indices: Array = _tracks[track]
		indices.sort_custom(func(a: int, b: int): return timeline[a].at < timeline[b].at)
		var starts := PackedFloat64Array()
		var ends := PackedFloat64Array()
		var leaf := 1
		while leaf < indices.size():
			leaf *= 2
		ends.resize(leaf * 2)
		ends.fill(-INF)
		for i in indices.size():
			var entry: Dictionary = timeline[indices[i]]
			var span := Rect2(ruler_x + float(entry.at) * pixels_per_unit, 0.0,
				maxf(float(entry.duration) * pixels_per_unit, MIN_BLOCK_WIDTH), 0.0)
			starts.append(span.position.x)
			ends[leaf + i] = span.end.x
		for i in range(leaf - 1, 0, -1):
			ends[i] = maxf(ends[i * 2], ends[i * 2 + 1])
		_tracks[track] = {"indices": indices, "starts": starts, "ends": ends, "leaf": leaf}

## Horizontal bounds are in timeline-local pixels, matching the drawn rectangles.
func query(track: int, left: float, right: float, result: Array[int]) -> void:
	if not _tracks.has(track):
		return
	var row: Dictionary = _tracks[track]
	_collect(row, 1, 0, row.leaf, left, right, result)

func _collect(row: Dictionary, node: int, first: int, last: int, left: float, right: float,
		result: Array[int]) -> void:
	if first >= row.starts.size() or row.starts[first] > right or row.ends[node] < left:
		return
	if last - first == 1:
		result.append(row.indices[first])
		return
	var mid := (first + last) >> 1
	_collect(row, node * 2, first, mid, left, right, result)
	_collect(row, node * 2 + 1, mid, last, left, right, result)
