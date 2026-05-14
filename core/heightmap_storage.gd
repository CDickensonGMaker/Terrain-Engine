extends RefCounted
class_name HeightmapStorage
## Large heightmap storage with efficient region access and interpolation
## Designed for 3km x 3km maps (1536 x 1536 cells at 2m resolution)

signal generation_complete
signal generation_progress(percent: float)

# Heightmap dimensions
var size: int = 1536  # Cells per side (3000m / 2m cell_size, rounded to power of 2 compatible)
var cell_size: float = 2.0  # Meters per cell
var height_scale: float = 280.0  # Max height in meters

# Raw heightmap data (normalized 0-1)
var data: PackedFloat32Array

# River accumulation data (for river extraction)
var river_accumulation: PackedFloat32Array

# Generation state
var is_generating: bool = false
var generation_thread: Thread


func _init(map_size_meters: float = 3000.0, cell_size_meters: float = 2.0) -> void:
	cell_size = cell_size_meters
	size = int(ceil(map_size_meters / cell_size_meters))
	# Round up to nearest power of 2 + 1 for clean chunk boundaries
	size = _next_chunk_aligned_size(size)
	data = PackedFloat32Array()
	river_accumulation = PackedFloat32Array()


func _next_chunk_aligned_size(s: int) -> int:
	## Round size to be cleanly divisible by chunk cells (128)
	const CHUNK_CELLS := 128
	return int(ceil(float(s) / CHUNK_CELLS)) * CHUNK_CELLS + 1


## Initialize with flat terrain (for testing)
func init_flat(height: float = 0.5) -> void:
	data.resize(size * size)
	data.fill(height)


## Get height at cell coordinates (no interpolation)
func get_cell(x: int, z: int) -> float:
	if x < 0 or x >= size or z < 0 or z >= size:
		return 0.0
	return data[z * size + x]


## Set height at cell coordinates
func set_cell(x: int, z: int, value: float) -> void:
	if x < 0 or x >= size or z < 0 or z >= size:
		return
	data[z * size + x] = clampf(value, 0.0, 1.0)


## Get height at world position with bilinear interpolation
func sample_world(world_x: float, world_z: float) -> float:
	var fx: float = world_x / cell_size
	var fz: float = world_z / cell_size
	return sample_bilinear(fx, fz) * height_scale


## Bilinear interpolation at cell coordinates (fractional)
func sample_bilinear(fx: float, fz: float) -> float:
	var x: int = int(fx)
	var z: int = int(fz)
	var dx: float = fx - x
	var dz: float = fz - z

	# Clamp to valid range
	x = clampi(x, 0, size - 2)
	z = clampi(z, 0, size - 2)

	# Get 4 corners
	var h00: float = data[z * size + x]
	var h10: float = data[z * size + x + 1]
	var h01: float = data[(z + 1) * size + x]
	var h11: float = data[(z + 1) * size + x + 1]

	# Bilinear interpolation
	var h0: float = lerpf(h00, h10, dx)
	var h1: float = lerpf(h01, h11, dx)
	return lerpf(h0, h1, dz)


## Get normal at world position
func get_normal_world(world_x: float, world_z: float) -> Vector3:
	var delta: float = cell_size

	var hL: float = sample_world(world_x - delta, world_z)
	var hR: float = sample_world(world_x + delta, world_z)
	var hD: float = sample_world(world_x, world_z - delta)
	var hU: float = sample_world(world_x, world_z + delta)

	return Vector3(hL - hR, 2.0 * delta, hD - hU).normalized()


## Extract a region of heightmap data for chunk generation
## Returns data for cells from (start_x, start_z) to (start_x + region_size, start_z + region_size)
func extract_region(start_x: int, start_z: int, region_size: int) -> PackedFloat32Array:
	var region := PackedFloat32Array()
	region.resize(region_size * region_size)

	for z in range(region_size):
		for x in range(region_size):
			var src_x: int = start_x + x
			var src_z: int = start_z + z

			if src_x >= 0 and src_x < size and src_z >= 0 and src_z < size:
				region[z * region_size + x] = data[src_z * size + src_x]
			else:
				region[z * region_size + x] = 0.0

	return region


## Get chunk coordinates from world position
func world_to_chunk(world_pos: Vector3, chunk_size_meters: float) -> Vector2i:
	return Vector2i(
		int(floor(world_pos.x / chunk_size_meters)),
		int(floor(world_pos.z / chunk_size_meters))
	)


## Get cell coordinates from world position
func world_to_cell(world_x: float, world_z: float) -> Vector2i:
	return Vector2i(
		int(floor(world_x / cell_size)),
		int(floor(world_z / cell_size))
	)


## Modify heightmap in a circular region (for damage/clearing)
func modify_region(center: Vector2i, radius: int, modifier: Callable) -> Rect2i:
	var min_x: int = maxi(0, center.x - radius)
	var max_x: int = mini(size, center.x + radius + 1)
	var min_z: int = maxi(0, center.y - radius)
	var max_z: int = mini(size, center.y + radius + 1)

	for z in range(min_z, max_z):
		for x in range(min_x, max_x):
			var dist: float = Vector2(x - center.x, z - center.y).length()
			if dist <= radius:
				var idx: int = z * size + x
				var falloff: float = 1.0 - smoothstep(0.0, float(radius), dist)
				data[idx] = modifier.call(data[idx], falloff)

	return Rect2i(min_x, min_z, max_x - min_x, max_z - min_z)


## Get river accumulation at cell (for river extraction)
func get_river_accumulation(x: int, z: int) -> float:
	if river_accumulation.size() == 0:
		return 0.0
	if x < 0 or x >= size or z < 0 or z >= size:
		return 0.0
	return river_accumulation[z * size + x]


## Get total world size in meters
func get_world_size() -> float:
	return size * cell_size


## Get memory usage in bytes
func get_memory_usage() -> int:
	return data.size() * 4 + river_accumulation.size() * 4


## Get heightmap as texture for shader use
func get_texture() -> ImageTexture:
	if data.is_empty():
		return null

	# Create image from heightmap data (R channel = height)
	var img := Image.create(size, size, false, Image.FORMAT_RF)

	for z in size:
		for x in size:
			var h := data[z * size + x]
			img.set_pixel(x, z, Color(h, h, h, 1.0))

	return ImageTexture.create_from_image(img)


## Debug: print stats
func print_stats() -> void:
	var min_h: float = 1.0
	var max_h: float = 0.0
	var total: float = 0.0

	for h in data:
		min_h = minf(min_h, h)
		max_h = maxf(max_h, h)
		total += h

	var avg_h: float = total / data.size() if data.size() > 0 else 0.0

	print("[HeightmapStorage] Size: %d x %d cells" % [size, size])
	print("[HeightmapStorage] World: %.0f x %.0f meters" % [get_world_size(), get_world_size()])
	print("[HeightmapStorage] Height: min=%.2f max=%.2f avg=%.2f (normalized)" % [min_h, max_h, avg_h])
	print("[HeightmapStorage] Memory: %.2f MB" % [get_memory_usage() / 1048576.0])
