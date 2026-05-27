extends RefCounted
class_name HydrologyMap
## Unified hydrology pass for terrain water.
##
## One generation-time computation that models water the way it actually behaves:
## rain lands on the high ground, cascades downhill, carves channels where flow
## concentrates (creeks -> rivers), and pools in depressions (ponds -> lakes).
##
## Pipeline (all O(n) / O(n log n), run ONCE - zero per-frame cost):
##   1. Priority-Flood + epsilon (Barnes et al. 2014) fills pits so every cell has a
##      monotonic downhill path to an outlet. The "filled" surface minus the real
##      terrain IS the standing water (ponds/lakes), with a correct flat pour level.
##   2. D8 flow direction on the filled surface (a downhill neighbor always exists
##      thanks to the epsilon tilt, except at outlets/borders).
##   3. Flow accumulation from the peaks down -> high accumulation = rivers/creeks.
##   4. Derive ponds/lakes (pooling), rivers/creeks (channels), swamps (flat + wet +
##      low ground) and coastal (sea-connected below sea level) from the same model.
##
## For large maps the heavy steps run on a downsampled grid (set `downsample`) and the
## resulting masks are upsampled back to heightmap resolution.

const WaterBodyDataClass := preload("res://water/water_body_data.gd")

# 8-neighbour offsets and their step distances (diagonals are longer).
const DIR8: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0),                   Vector2i(1, 0),
	Vector2i(-1, 1),  Vector2i(0, 1),  Vector2i(1, 1)
]
const DIST8: Array[float] = [
	1.41421356, 1.0, 1.41421356,
	1.0,             1.0,
	1.41421356, 1.0, 1.41421356
]

# --- Tunable parameters -------------------------------------------------------

## Downsample factor for the heavy compute (1 = full heightmap resolution).
## e.g. 4 turns a 1537x1537 heightmap into a ~385x385 hydrology grid.
var downsample: int = 1

## A cell is standing water (pond/lake) when filled - terrain exceeds this (meters).
var min_lake_depth: float = 0.4

## Tiny upward tilt applied while flood-filling so flats still drain (meters).
var flood_epsilon: float = 0.001

## Flow-accumulation threshold (in upstream hydrology cells) for a channel to form.
## A channel appears once this many cells drain through it; higher = fewer, larger
## waterways (less spaghetti, cheaper to render). Creek vs river is split by width.
var creek_threshold: float = 300.0

## River width = base + scale * sqrt(accumulation) (meters), clamped.
var river_width_scale: float = 0.35
var river_width_base: float = 2.0
var river_width_max: float = 40.0
var min_river_points: int = 8

## Rivers are only drawn where the ground is gentle enough to hold a visible channel
## (real valley floors). Steep fall-line drainage is left as terrain, not water.
var river_max_slope: float = 0.15  # ~8.5 degrees

## Swamp: flat, low, moderately wet ground (NOT hillsides).
var swamp_max_slope: float = 0.09          # ~5 degrees
var swamp_elevation_fraction: float = 0.30 # below 30% of height_scale
var swamp_min_accum: float = 25.0          # wet enough to be marshy
var swamp_depth: float = 0.4               # shallow standing water (meters)

## Coastal (only used when ocean_edges != 0). Bitmask 1=N 2=E 4=S 8=W.
var ocean_edges: int = 0
var sea_level: float = 5.0

# --- Outputs (heightmap resolution) ------------------------------------------

## Full-resolution side length (== heightmap.size).
var size: int = 0
## Meters per heightmap cell.
var cell_size: float = 2.0
## Per heightmap cell: WaterBodyData.Type code (0 none .. 6 coastal).
var water_type_full: PackedByteArray = PackedByteArray()
## Per heightmap cell: flat water-surface height in meters (valid where wet).
var water_surface_full: PackedFloat32Array = PackedFloat32Array()
## River/creek polylines: Array of { points: PackedVector2Array, widths: PackedFloat32Array }.
var rivers: Array = []

# --- Internal (hydrology resolution) -----------------------------------------

var _hsize: int = 0
var _hcell: float = 2.0
var _height_scale: float = 1.0
var _elev: PackedFloat32Array = PackedFloat32Array()      # terrain, meters
var _filled: PackedFloat32Array = PackedFloat32Array()    # depression-filled, meters
var _flow: PackedByteArray = PackedByteArray()            # D8 dir index, 255 = sink
var _accum: PackedFloat32Array = PackedFloat32Array()     # upstream cell count
var _type_h: PackedByteArray = PackedByteArray()          # type per hydrology cell
var _surface_h: PackedFloat32Array = PackedFloat32Array() # surface per hydrology cell

# Min-heap for priority-flood (parallel arrays).
var _heap_pri: PackedFloat32Array = PackedFloat32Array()
var _heap_idx: PackedInt32Array = PackedInt32Array()


## Run the full hydrology pass on a HeightmapStorage.
func generate(heightmap: RefCounted) -> void:
	size = heightmap.size
	cell_size = heightmap.cell_size
	_height_scale = heightmap.height_scale
	downsample = maxi(1, downsample)

	_build_downsampled_elevation(heightmap)
	_priority_flood()
	_compute_flow_directions()
	_compute_flow_accumulation()
	_classify_cells()
	if ocean_edges != 0:
		_flood_coastal()
	_extract_rivers()
	_upsample_outputs()


# -----------------------------------------------------------------------------
# STEP 0: downsample terrain to the hydrology grid (in meters)
# -----------------------------------------------------------------------------
func _build_downsampled_elevation(heightmap: RefCounted) -> void:
	_hcell = cell_size * downsample
	_hsize = int(ceil(float(size) / downsample))
	var n: int = _hsize * _hsize
	_elev.resize(n)

	for hz in range(_hsize):
		for hx in range(_hsize):
			# Average the block of heightmap cells this hydrology cell covers.
			var sum: float = 0.0
			var count: int = 0
			var base_x: int = hx * downsample
			var base_z: int = hz * downsample
			for dz in range(downsample):
				var sz: int = base_z + dz
				if sz >= size:
					break
				for dx in range(downsample):
					var sx: int = base_x + dx
					if sx >= size:
						break
					sum += heightmap.get_cell(sx, sz)
					count += 1
			var norm: float = (sum / count) if count > 0 else 0.0
			_elev[hz * _hsize + hx] = norm * _height_scale


# -----------------------------------------------------------------------------
# STEP 1: Priority-Flood + epsilon -> filled surface (removes pits)
# -----------------------------------------------------------------------------
func _priority_flood() -> void:
	var n: int = _hsize * _hsize
	_filled.resize(n)
	var closed := PackedByteArray()
	closed.resize(n)
	closed.fill(0)

	_heap_pri.clear()
	_heap_idx.clear()

	# Seed the heap with every border cell (these drain off the map edge).
	for x in range(_hsize):
		_heap_seed(x, 0, closed)
		_heap_seed(x, _hsize - 1, closed)
	for z in range(1, _hsize - 1):
		_heap_seed(0, z, closed)
		_heap_seed(_hsize - 1, z, closed)

	while _heap_idx.size() > 0:
		var c: int = _heap_pop()
		var cf: float = _filled[c]
		var cx: int = c % _hsize
		var cz: int = c / _hsize

		for d in range(8):
			var off: Vector2i = DIR8[d]
			var nx: int = cx + off.x
			var nz: int = cz + off.y
			if nx < 0 or nx >= _hsize or nz < 0 or nz >= _hsize:
				continue
			var ni: int = nz * _hsize + nx
			if closed[ni] != 0:
				continue
			closed[ni] = 1
			# Fill to at least (parent + epsilon) so flats keep a downhill path.
			_filled[ni] = maxf(_elev[ni], cf + flood_epsilon)
			_heap_push(_filled[ni], ni)


func _heap_seed(x: int, z: int, closed: PackedByteArray) -> void:
	var i: int = z * _hsize + x
	if closed[i] != 0:
		return
	closed[i] = 1
	_filled[i] = _elev[i]
	_heap_push(_elev[i], i)


# Binary min-heap on parallel (priority, index) arrays.
func _heap_push(pri: float, idx: int) -> void:
	_heap_pri.append(pri)
	_heap_idx.append(idx)
	var i: int = _heap_idx.size() - 1
	while i > 0:
		var parent: int = (i - 1) >> 1
		if _heap_pri[parent] <= _heap_pri[i]:
			break
		_heap_swap(i, parent)
		i = parent


func _heap_pop() -> int:
	var top: int = _heap_idx[0]
	var last: int = _heap_idx.size() - 1
	_heap_pri[0] = _heap_pri[last]
	_heap_idx[0] = _heap_idx[last]
	_heap_pri.remove_at(last)
	_heap_idx.remove_at(last)

	var count: int = _heap_idx.size()
	var i: int = 0
	while true:
		var left: int = 2 * i + 1
		var right: int = 2 * i + 2
		var smallest: int = i
		if left < count and _heap_pri[left] < _heap_pri[smallest]:
			smallest = left
		if right < count and _heap_pri[right] < _heap_pri[smallest]:
			smallest = right
		if smallest == i:
			break
		_heap_swap(i, smallest)
		i = smallest
	return top


func _heap_swap(a: int, b: int) -> void:
	var tp: float = _heap_pri[a]
	_heap_pri[a] = _heap_pri[b]
	_heap_pri[b] = tp
	var ti: int = _heap_idx[a]
	_heap_idx[a] = _heap_idx[b]
	_heap_idx[b] = ti


# -----------------------------------------------------------------------------
# STEP 2: D8 flow direction on the filled surface
# -----------------------------------------------------------------------------
func _compute_flow_directions() -> void:
	var n: int = _hsize * _hsize
	_flow.resize(n)
	_flow.fill(255)

	for z in range(_hsize):
		for x in range(_hsize):
			var i: int = z * _hsize + x
			var h: float = _filled[i]
			var best_slope: float = 0.0
			var best_dir: int = 255
			for d in range(8):
				var off: Vector2i = DIR8[d]
				var nx: int = x + off.x
				var nz: int = z + off.y
				if nx < 0 or nx >= _hsize or nz < 0 or nz >= _hsize:
					# Off-map edge is a valid drain for border cells.
					best_dir = d
					best_slope = INF
					continue
				var drop: float = h - _filled[nz * _hsize + nx]
				if drop > 0.0:
					var slope: float = drop / DIST8[d]
					if slope > best_slope:
						best_slope = slope
						best_dir = d
			_flow[i] = best_dir


# -----------------------------------------------------------------------------
# STEP 3: Flow accumulation (topological, from peaks downhill)
# -----------------------------------------------------------------------------
func _compute_flow_accumulation() -> void:
	var n: int = _hsize * _hsize
	_accum.resize(n)
	_accum.fill(1.0)  # every cell contributes its own rainfall

	var in_degree := PackedInt32Array()
	in_degree.resize(n)
	in_degree.fill(0)

	for z in range(_hsize):
		for x in range(_hsize):
			var dir: int = _flow[z * _hsize + x]
			if dir < 8:
				var off: Vector2i = DIR8[dir]
				var nx: int = x + off.x
				var nz: int = z + off.y
				if nx >= 0 and nx < _hsize and nz >= 0 and nz < _hsize:
					in_degree[nz * _hsize + nx] += 1

	# Process sources (no upstream) first, push accumulation downstream.
	var queue := PackedInt32Array()
	for i in range(n):
		if in_degree[i] == 0:
			queue.append(i)

	var head: int = 0
	while head < queue.size():
		var i: int = queue[head]
		head += 1
		var dir: int = _flow[i]
		if dir >= 8:
			continue
		var off: Vector2i = DIR8[dir]
		var x: int = i % _hsize
		var z: int = i / _hsize
		var nx: int = x + off.x
		var nz: int = z + off.y
		if nx < 0 or nx >= _hsize or nz < 0 or nz >= _hsize:
			continue
		var ni: int = nz * _hsize + nx
		_accum[ni] += _accum[i]
		in_degree[ni] -= 1
		if in_degree[ni] == 0:
			queue.append(ni)


# -----------------------------------------------------------------------------
# STEP 4: classify each hydrology cell (lake / swamp); rivers added later
# -----------------------------------------------------------------------------
func _classify_cells() -> void:
	var n: int = _hsize * _hsize
	_type_h.resize(n)
	_type_h.fill(0)
	_surface_h.resize(n)
	_surface_h.fill(0.0)

	var swamp_elev_max: float = swamp_elevation_fraction * _height_scale

	for z in range(_hsize):
		for x in range(_hsize):
			var i: int = z * _hsize + x
			var terrain: float = _elev[i]
			var pool_depth: float = _filled[i] - terrain

			if pool_depth > min_lake_depth:
				# Standing water: flat surface at the filled (pour) level.
				_type_h[i] = WaterBodyDataClass.Type.LAKE
				_surface_h[i] = _filled[i]
				continue

			# Swamp: flat, low, moderately wet ground that is NOT a channel.
			if terrain < swamp_elev_max and _accum[i] >= swamp_min_accum \
					and _accum[i] < creek_threshold:
				if _local_slope(x, z) < swamp_max_slope:
					_type_h[i] = WaterBodyDataClass.Type.SWAMP
					_surface_h[i] = terrain + swamp_depth


func _local_slope(x: int, z: int) -> float:
	var h: float = _elev[z * _hsize + x]
	var max_diff: float = 0.0
	for d in range(8):
		var off: Vector2i = DIR8[d]
		var nx: int = x + off.x
		var nz: int = z + off.y
		if nx < 0 or nx >= _hsize or nz < 0 or nz >= _hsize:
			continue
		var diff: float = absf(h - _elev[nz * _hsize + nx]) / (DIST8[d] * _hcell)
		max_diff = maxf(max_diff, diff)
	return max_diff


# -----------------------------------------------------------------------------
# STEP 5: coastal flood from ocean edges (only when ocean_edges set)
# -----------------------------------------------------------------------------
func _flood_coastal() -> void:
	var n: int = _hsize * _hsize
	var visited := PackedByteArray()
	visited.resize(n)
	visited.fill(0)
	var queue := PackedInt32Array()

	var seed_edge := func(x: int, z: int) -> void:
		var i: int = z * _hsize + x
		if visited[i] == 0 and _elev[i] < sea_level:
			visited[i] = 1
			queue.append(i)

	if ocean_edges & 1:  # North (z = 0)
		for x in range(_hsize):
			seed_edge.call(x, 0)
	if ocean_edges & 4:  # South (z = max)
		for x in range(_hsize):
			seed_edge.call(x, _hsize - 1)
	if ocean_edges & 8:  # West (x = 0)
		for z in range(_hsize):
			seed_edge.call(0, z)
	if ocean_edges & 2:  # East (x = max)
		for z in range(_hsize):
			seed_edge.call(_hsize - 1, z)

	var head: int = 0
	while head < queue.size():
		var i: int = queue[head]
		head += 1
		_type_h[i] = WaterBodyDataClass.Type.COASTAL
		_surface_h[i] = sea_level
		var x: int = i % _hsize
		var z: int = i / _hsize
		for d in range(8):
			var off: Vector2i = DIR8[d]
			var nx: int = x + off.x
			var nz: int = z + off.y
			if nx < 0 or nx >= _hsize or nz < 0 or nz >= _hsize:
				continue
			var ni: int = nz * _hsize + nx
			if visited[ni] == 0 and _elev[ni] < sea_level:
				visited[ni] = 1
				queue.append(ni)


# -----------------------------------------------------------------------------
# STEP 6: trace river/creek polylines from flow accumulation
# -----------------------------------------------------------------------------
func _extract_rivers() -> void:
	rivers.clear()
	var n: int = _hsize * _hsize

	# River cells = enough upstream flow, and not already standing/sea water.
	var is_channel := PackedByteArray()
	is_channel.resize(n)
	is_channel.fill(0)
	for i in range(n):
		var t: int = _type_h[i]
		if (t == WaterBodyDataClass.Type.LAKE or t == WaterBodyDataClass.Type.COASTAL):
			continue
		if _accum[i] < creek_threshold:
			continue
		# Valley floors only - skip steep fall-line drainage so rivers don't render
		# as flat slabs plastered down hillsides.
		if _local_slope(i % _hsize, i / _hsize) > river_max_slope:
			continue
		is_channel[i] = 1

	# Sources = channel cells with no channel cell flowing into them.
	var visited := PackedByteArray()
	visited.resize(n)
	visited.fill(0)

	for z in range(_hsize):
		for x in range(_hsize):
			var i: int = z * _hsize + x
			if is_channel[i] == 0:
				continue
			if _has_upstream_channel(x, z, is_channel):
				continue
			_trace_channel(x, z, is_channel, visited)


func _has_upstream_channel(x: int, z: int, is_channel: PackedByteArray) -> bool:
	for d in range(8):
		var off: Vector2i = DIR8[d]
		var nx: int = x + off.x
		var nz: int = z + off.y
		if nx < 0 or nx >= _hsize or nz < 0 or nz >= _hsize:
			continue
		var ni: int = nz * _hsize + nx
		if is_channel[ni] == 0:
			continue
		var ndir: int = _flow[ni]
		if ndir < 8:
			var noff: Vector2i = DIR8[ndir]
			if nx + noff.x == x and nz + noff.y == z:
				return true
	return false


func _trace_channel(sx: int, sz: int, is_channel: PackedByteArray, visited: PackedByteArray) -> void:
	var points := PackedVector2Array()
	var widths := PackedFloat32Array()
	var x: int = sx
	var z: int = sz

	while true:
		var i: int = z * _hsize + x
		if visited[i] == 1:
			break
		visited[i] = 1

		# World position at the centre of this hydrology cell.
		var wpos := Vector2((x + 0.5) * _hcell, (z + 0.5) * _hcell)
		var w: float = clampf(river_width_base + river_width_scale * sqrt(_accum[i]),
				river_width_base, river_width_max)
		points.append(wpos)
		widths.append(w)

		# Mark the channel into the type grid (creek vs river by width).
		_type_h[i] = WaterBodyDataClass.Type.CREEK if w < 6.0 else WaterBodyDataClass.Type.RIVER

		var dir: int = _flow[i]
		if dir >= 8:
			break
		var off: Vector2i = DIR8[dir]
		var nx: int = x + off.x
		var nz: int = z + off.y
		if nx < 0 or nx >= _hsize or nz < 0 or nz >= _hsize:
			break
		# Run into a lake or the sea: stop the channel there.
		var nt: int = _type_h[nz * _hsize + nx]
		if nt == WaterBodyDataClass.Type.LAKE or nt == WaterBodyDataClass.Type.COASTAL:
			points.append(Vector2((nx + 0.5) * _hcell, (nz + 0.5) * _hcell))
			widths.append(widths[widths.size() - 1])
			break
		x = nx
		z = nz

	if points.size() >= min_river_points:
		rivers.append({ "points": points, "widths": widths })


# -----------------------------------------------------------------------------
# STEP 7: upsample type/surface masks back to heightmap resolution
# -----------------------------------------------------------------------------
func _upsample_outputs() -> void:
	var n: int = size * size
	water_type_full.resize(n)
	water_surface_full.resize(n)

	if downsample == 1:
		water_type_full = _type_h.duplicate()
		water_surface_full = _surface_h.duplicate()
		return

	for z in range(size):
		var hz: int = mini(z / downsample, _hsize - 1)
		for x in range(size):
			var hx: int = mini(x / downsample, _hsize - 1)
			var hi: int = hz * _hsize + hx
			var fi: int = z * size + x
			water_type_full[fi] = _type_h[hi]
			water_surface_full[fi] = _surface_h[hi]


# -----------------------------------------------------------------------------
# PUBLIC: extract connected standing-water bodies as cell groups for meshing.
# Returns Array of dictionaries:
#   { type:int, cells:Array[Vector2i], surface:float, depth:float, bounds:Rect2 }
# Rivers/creeks are NOT included here (use `rivers` polylines for those).
# -----------------------------------------------------------------------------
func extract_static_bodies(heightmap: RefCounted) -> Array:
	var bodies: Array = []
	var n: int = size * size
	var seen := PackedByteArray()
	seen.resize(n)
	seen.fill(0)

	for z in range(size):
		for x in range(size):
			var i: int = z * size + x
			if seen[i] == 1:
				continue
			var t: int = water_type_full[i]
			if t != WaterBodyDataClass.Type.LAKE \
					and t != WaterBodyDataClass.Type.SWAMP \
					and t != WaterBodyDataClass.Type.COASTAL:
				seen[i] = 1
				continue
			bodies.append(_flood_component(x, z, t, seen, heightmap))

	return bodies


func _flood_component(start_x: int, start_z: int, type_code: int,
		seen: PackedByteArray, heightmap: RefCounted) -> Dictionary:
	var cells: Array[Vector2i] = []
	var stack := PackedInt32Array()
	stack.append(start_z * size + start_x)
	seen[start_z * size + start_x] = 1

	var surface_sum: float = 0.0
	var depth_sum: float = 0.0
	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)

	while stack.size() > 0:
		var i: int = stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		var x: int = i % size
		var z: int = i / size
		cells.append(Vector2i(x, z))

		var surf: float = water_surface_full[i]
		surface_sum += surf
		var terrain: float = heightmap.get_cell(x, z) * _height_scale
		depth_sum += maxf(0.0, surf - terrain)

		var wx: float = x * cell_size
		var wz: float = z * cell_size
		min_pt.x = minf(min_pt.x, wx)
		min_pt.y = minf(min_pt.y, wz)
		max_pt.x = maxf(max_pt.x, wx + cell_size)
		max_pt.y = maxf(max_pt.y, wz + cell_size)

		for d in range(8):
			var off: Vector2i = DIR8[d]
			var nx: int = x + off.x
			var nz: int = z + off.y
			if nx < 0 or nx >= size or nz < 0 or nz >= size:
				continue
			var ni: int = nz * size + nx
			if seen[ni] == 1:
				continue
			if water_type_full[ni] == type_code:
				seen[ni] = 1
				stack.append(ni)

	var count: int = cells.size()
	return {
		"type": type_code,
		"cells": cells,
		"surface": (surface_sum / count) if count > 0 else 0.0,
		"depth": (depth_sum / count) if count > 0 else 0.0,
		"bounds": Rect2(min_pt, max_pt - min_pt),
	}
