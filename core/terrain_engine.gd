extends Node
## Terrain Engine - Advanced heightmap generation with Vietnam-style terrain
## Features: Domain warping, ridged multifractal, hydraulic erosion
## Based on research from Red Blob Games, Nick McDonald, and The Mountains of Madness

signal terrain_generated(heightmap: Image)
signal terrain_updated(region: Rect2i)
signal erosion_progress(percent: float)

# Generation parameters
var seed_value: int = 0
# Terrain size: 1537 cells = 3074m at 2m/cell (~3km map)
# Supports up to 1536+ for large open worlds. Use power of 2 + 1 for clean LOD.
var terrain_size: int = 1537

# Heightmap data
var heightmap: Image
var heightmap_data: PackedFloat32Array

# Terrain scale - based on real Vietnam topography
# Real: min -3m, max 2809m (Fansipan), avg 173m
var cell_size: float = 2.0  # Meters per heightmap cell
var height_scale: float = 280.0  # Max terrain height in meters

# Noise generators
var base_noise: FastNoiseLite
var warp_noise_x: FastNoiseLite
var warp_noise_y: FastNoiseLite
var ridge_noise: FastNoiseLite
var detail_noise: FastNoiseLite

# Generation presets
enum TerrainPreset {
	ROLLING_HILLS,      # Gentle Vietnam highlands
	STEEP_MOUNTAINS,    # Dramatic peaks with cliffs
	RIVER_VALLEY,       # Low center with ridges
	COASTAL_HILLS,      # Gradual slope to flat
	PLATEAU,            # Flat top with cliff edges
	CUSTOM              # Manual parameter control
}

var current_preset: TerrainPreset = TerrainPreset.ROLLING_HILLS

# Advanced parameters with defaults for Vietnam terrain
var params: Dictionary = {
	# Base terrain
	"base_frequency": 0.002,
	"base_octaves": 5,
	"base_lacunarity": 2.0,
	"base_persistence": 0.5,

	# Domain warping (organic twisting)
	"warp_enabled": true,
	"warp_strength": 40.0,
	"warp_frequency": 0.003,

	# Ridged multifractal (sharp mountain ridges)
	"ridge_enabled": true,
	"ridge_frequency": 0.004,
	"ridge_octaves": 4,
	"ridge_sharpness": 2.0,  # Power for ridge sharpening
	"ridge_blend": 0.4,      # How much ridge affects terrain
	"ridge_threshold": 0.3,  # Only apply ridges above this height

	# Detail noise
	"detail_frequency": 0.02,
	"detail_amplitude": 0.08,

	# Cliff enhancement
	"cliff_enabled": true,
	"cliff_threshold": 0.25,
	"cliff_sharpness": 3.0,

	# Smoothing
	"smoothing_passes": 2,
	"smoothing_strength": 1.0,

	# Erosion simulation (disabled by default - can freeze on slow machines)
	"erosion_enabled": false,
	"erosion_iterations": 5000,
	"erosion_inertia": 0.3,
	"erosion_capacity": 8.0,
	"erosion_deposition": 0.3,
	"erosion_erosion": 0.7,
	"erosion_evaporation": 0.02,
	"erosion_radius": 3,
	"erosion_min_slope": 0.01,
}

# Preset parameter sets
var preset_params: Dictionary = {
	TerrainPreset.ROLLING_HILLS: {
		"base_frequency": 0.002,
		"base_octaves": 4,
		"warp_enabled": true,
		"warp_strength": 30.0,
		"ridge_enabled": true,
		"ridge_blend": 0.3,
		"ridge_threshold": 0.35,
		"cliff_enabled": true,
		"cliff_sharpness": 2.0,
		"smoothing_passes": 3,
		"erosion_enabled": false,
		"erosion_iterations": 5000,
	},
	TerrainPreset.STEEP_MOUNTAINS: {
		"base_frequency": 0.003,
		"base_octaves": 5,
		"warp_enabled": true,
		"warp_strength": 50.0,
		"ridge_enabled": true,
		"ridge_blend": 0.6,
		"ridge_threshold": 0.2,
		"ridge_sharpness": 2.5,
		"cliff_enabled": true,
		"cliff_sharpness": 4.0,
		"smoothing_passes": 1,
		"erosion_enabled": false,
		"erosion_iterations": 60000,
	},
	TerrainPreset.RIVER_VALLEY: {
		"base_frequency": 0.0015,
		"base_octaves": 4,
		"warp_enabled": true,
		"warp_strength": 25.0,
		"ridge_enabled": true,
		"ridge_blend": 0.35,
		"ridge_threshold": 0.4,
		"cliff_enabled": true,
		"cliff_sharpness": 2.5,
		"smoothing_passes": 2,
		"erosion_enabled": false,
		"erosion_iterations": 80000,  # More erosion for valley carving
	},
	TerrainPreset.COASTAL_HILLS: {
		"base_frequency": 0.0018,
		"base_octaves": 4,
		"warp_enabled": true,
		"warp_strength": 20.0,
		"ridge_enabled": false,
		"cliff_enabled": true,
		"cliff_sharpness": 1.5,
		"smoothing_passes": 3,
		"erosion_enabled": false,
		"erosion_iterations": 30000,
	},
	TerrainPreset.PLATEAU: {
		"base_frequency": 0.0012,
		"base_octaves": 3,
		"warp_enabled": false,
		"ridge_enabled": false,
		"cliff_enabled": true,
		"cliff_threshold": 0.15,
		"cliff_sharpness": 6.0,
		"smoothing_passes": 1,
		"erosion_enabled": false,
		"erosion_iterations": 20000,
	},
}


func _ready() -> void:
	_init_noise()
	set_preset(TerrainPreset.ROLLING_HILLS)


func _init_noise() -> void:
	# Base terrain noise
	base_noise = FastNoiseLite.new()
	base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM

	# Domain warping noise (two separate for X and Y offsets)
	warp_noise_x = FastNoiseLite.new()
	warp_noise_x.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	warp_noise_x.fractal_type = FastNoiseLite.FRACTAL_FBM
	warp_noise_x.fractal_octaves = 3

	warp_noise_y = FastNoiseLite.new()
	warp_noise_y.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	warp_noise_y.fractal_type = FastNoiseLite.FRACTAL_FBM
	warp_noise_y.fractal_octaves = 3

	# Ridged multifractal noise
	ridge_noise = FastNoiseLite.new()
	ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED

	# Detail noise
	detail_noise = FastNoiseLite.new()
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.fractal_octaves = 3


func set_preset(preset: TerrainPreset) -> void:
	current_preset = preset
	if preset != TerrainPreset.CUSTOM and preset_params.has(preset):
		# Merge preset params into current params
		for key in preset_params[preset]:
			params[key] = preset_params[preset][key]
	_apply_params()


func set_param(key: String, value: Variant) -> void:
	params[key] = value
	current_preset = TerrainPreset.CUSTOM
	_apply_params()


func _apply_params() -> void:
	base_noise.frequency = params.get("base_frequency", 0.002)
	base_noise.fractal_octaves = params.get("base_octaves", 5)
	base_noise.fractal_lacunarity = params.get("base_lacunarity", 2.0)
	base_noise.fractal_gain = params.get("base_persistence", 0.5)

	warp_noise_x.frequency = params.get("warp_frequency", 0.003)
	warp_noise_y.frequency = params.get("warp_frequency", 0.003)

	ridge_noise.frequency = params.get("ridge_frequency", 0.004)
	ridge_noise.fractal_octaves = params.get("ridge_octaves", 4)

	detail_noise.frequency = params.get("detail_frequency", 0.02)


func randomize_seed() -> void:
	seed_value = randi()


func generate(new_seed: int = -1) -> void:
	if new_seed >= 0:
		seed_value = new_seed
	else:
		randomize_seed()

	# Set seeds for all noise generators
	base_noise.seed = seed_value
	warp_noise_x.seed = seed_value + 100
	warp_noise_y.seed = seed_value + 200
	ridge_noise.seed = seed_value + 300
	detail_noise.seed = seed_value + 400

	heightmap_data.resize(terrain_size * terrain_size)

	# Step 1: Generate base terrain with domain warping
	_generate_base_with_warping()

	# Step 2: Apply ridged multifractal for mountain ridges
	if params.get("ridge_enabled", true):
		_apply_ridged_multifractal()

	# Step 3: Add detail noise
	_apply_detail_noise()

	# Step 4: Apply cliff sharpening
	if params.get("cliff_enabled", true):
		_apply_cliff_enhancement()

	# Step 5: Smooth for clean rolling hills
	var smooth_passes: int = params.get("smoothing_passes", 2)
	for i in range(smooth_passes):
		_smooth_heightmap()

	# Step 6: Hydraulic erosion simulation
	if params.get("erosion_enabled", true):
		_simulate_hydraulic_erosion()

	# Final normalization
	_normalize_heightmap()

	# Create image
	_create_heightmap_image()

	terrain_generated.emit(heightmap)


func _generate_base_with_warping() -> void:
	## Generate base terrain with optional domain warping
	## Domain warping creates organic, twisted patterns like tectonic deformation

	var warp_enabled: bool = params.get("warp_enabled", true)
	var warp_strength: float = params.get("warp_strength", 40.0)

	for y in range(terrain_size):
		for x in range(terrain_size):
			var idx: int = y * terrain_size + x

			var sample_x: float = float(x)
			var sample_y: float = float(y)

			# Apply domain warping if enabled
			if warp_enabled:
				# Get warp offsets from separate noise functions
				var warp_x: float = warp_noise_x.get_noise_2d(x, y) * warp_strength
				var warp_y: float = warp_noise_y.get_noise_2d(x, y) * warp_strength

				sample_x += warp_x
				sample_y += warp_y

			# Sample base noise at (potentially warped) coordinates
			var height: float = base_noise.get_noise_2d(sample_x, sample_y)
			height = (height + 1.0) * 0.5  # Normalize to 0-1

			heightmap_data[idx] = height


func _apply_ridged_multifractal() -> void:
	## Apply ridged multifractal noise for sharp mountain ridges
	## Formula: n = abs(n); n = offset - n; n = n * n
	## This turns smooth valleys into sharp ridges

	var ridge_blend: float = params.get("ridge_blend", 0.4)
	var ridge_sharpness: float = params.get("ridge_sharpness", 2.0)
	var ridge_threshold: float = params.get("ridge_threshold", 0.3)

	for y in range(terrain_size):
		for x in range(terrain_size):
			var idx: int = y * terrain_size + x
			var base_height: float = heightmap_data[idx]

			# Only apply ridges to elevated areas (creates realistic mountain ranges)
			if base_height < ridge_threshold:
				continue

			# Get ridged noise value
			var ridge: float = ridge_noise.get_noise_2d(x, y)

			# Transform to ridged multifractal
			# 1. Take absolute value (valleys become peaks)
			ridge = abs(ridge)
			# 2. Invert (1.0 - x makes peaks into ridges)
			ridge = 1.0 - ridge
			# 3. Sharpen with power function
			ridge = pow(ridge, ridge_sharpness)

			# Height-dependent blending (higher areas get more ridge detail)
			var height_factor: float = smoothstep(ridge_threshold, ridge_threshold + 0.3, base_height)
			var blend: float = ridge_blend * height_factor

			heightmap_data[idx] = base_height + ridge * blend * 0.3


func _apply_detail_noise() -> void:
	## Add fine detail to the terrain
	var detail_amp: float = params.get("detail_amplitude", 0.08)

	for y in range(terrain_size):
		for x in range(terrain_size):
			var idx: int = y * terrain_size + x

			var detail: float = detail_noise.get_noise_2d(x, y)
			detail = (detail + 1.0) * 0.5 - 0.5  # Center around 0

			heightmap_data[idx] += detail * detail_amp


func _apply_cliff_enhancement() -> void:
	## Enhance steep areas to create dramatic cliffs
	## Uses gradient-based detection and terracing

	var threshold: float = params.get("cliff_threshold", 0.25)
	var sharpness: float = params.get("cliff_sharpness", 3.0)

	# Calculate gradients
	var gradients: PackedFloat32Array
	gradients.resize(terrain_size * terrain_size)

	for y in range(1, terrain_size - 1):
		for x in range(1, terrain_size - 1):
			var idx: int = y * terrain_size + x

			# Central difference gradient
			var gx: float = (heightmap_data[idx + 1] - heightmap_data[idx - 1]) * 0.5
			var gy: float = (heightmap_data[idx + terrain_size] - heightmap_data[idx - terrain_size]) * 0.5

			gradients[idx] = sqrt(gx * gx + gy * gy)

	# Apply cliff sharpening where gradient is high
	for y in range(1, terrain_size - 1):
		for x in range(1, terrain_size - 1):
			var idx: int = y * terrain_size + x
			var grad: float = gradients[idx]

			if grad > threshold * 0.5:
				var h: float = heightmap_data[idx]

				# Create terrace effect
				var levels: float = 8.0 + sharpness * 2.0
				var level_h: float = round(h * levels) / levels

				# Blend based on gradient steepness
				var blend: float = smoothstep(threshold * 0.5, threshold, grad)
				blend = pow(blend, 1.0 / sharpness)

				heightmap_data[idx] = lerp(h, level_h, blend * 0.4)


func _smooth_heightmap() -> void:
	## Gaussian smoothing for clean rolling hills
	var temp: PackedFloat32Array
	temp.resize(terrain_size * terrain_size)

	var strength: float = params.get("smoothing_strength", 1.0)

	# 3x3 Gaussian kernel
	var kernel: Array[float] = [
		1.0/16.0, 2.0/16.0, 1.0/16.0,
		2.0/16.0, 4.0/16.0, 2.0/16.0,
		1.0/16.0, 2.0/16.0, 1.0/16.0
	]

	for y in range(1, terrain_size - 1):
		for x in range(1, terrain_size - 1):
			var sum: float = 0.0
			var ki: int = 0

			for ky in range(-1, 2):
				for kx in range(-1, 2):
					var sample_idx: int = (y + ky) * terrain_size + (x + kx)
					sum += heightmap_data[sample_idx] * kernel[ki]
					ki += 1

			var idx: int = y * terrain_size + x
			temp[idx] = lerp(heightmap_data[idx], sum, strength)

	# Copy back (preserving edges)
	for y in range(1, terrain_size - 1):
		for x in range(1, terrain_size - 1):
			var idx: int = y * terrain_size + x
			heightmap_data[idx] = temp[idx]


func _simulate_hydraulic_erosion() -> void:
	## Particle-based hydraulic erosion simulation
	## Based on Nick McDonald's implementation and Hans Theobald Beyer's algorithm
	## Creates realistic river valleys and rounded hills

	var iterations: int = params.get("erosion_iterations", 50000)
	var inertia: float = params.get("erosion_inertia", 0.3)
	var capacity_mult: float = params.get("erosion_capacity", 8.0)
	var deposition_rate: float = params.get("erosion_deposition", 0.3)
	var erosion_rate: float = params.get("erosion_erosion", 0.7)
	var evaporation: float = params.get("erosion_evaporation", 0.02)
	var erosion_radius: int = params.get("erosion_radius", 3)
	var min_slope: float = params.get("erosion_min_slope", 0.01)

	var max_lifetime: int = 64
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 1000

	@warning_ignore("integer_division")
	var progress_step: int = maxi(1, iterations / 10)
	for i in range(iterations):
		# Report progress every 10%
		if i % progress_step == 0:
			erosion_progress.emit(float(i) / float(iterations))

		# Spawn droplet at random position
		var pos := Vector2(
			rng.randf() * (terrain_size - 2) + 1,
			rng.randf() * (terrain_size - 2) + 1
		)
		var dir := Vector2.ZERO
		var speed: float = 1.0
		var water: float = 1.0
		var sediment: float = 0.0

		for life in range(max_lifetime):
			var cell_x: int = int(pos.x)
			var cell_y: int = int(pos.y)

			if cell_x < 1 or cell_x >= terrain_size - 1 or cell_y < 1 or cell_y >= terrain_size - 1:
				break

			# Calculate gradient using bilinear interpolation
			var grad := _calculate_gradient(pos)

			# Update direction with inertia
			dir = dir * inertia - grad * (1.0 - inertia)
			if dir.length_squared() > 0:
				dir = dir.normalized()
			else:
				# Random direction if flat
				var angle: float = rng.randf() * TAU
				dir = Vector2(cos(angle), sin(angle))

			# Move droplet
			var new_pos: Vector2 = pos + dir

			# Check bounds
			if new_pos.x < 1 or new_pos.x >= terrain_size - 1 or new_pos.y < 1 or new_pos.y >= terrain_size - 1:
				break

			# Calculate height difference
			var old_height: float = _get_interpolated_height(pos)
			var new_height: float = _get_interpolated_height(new_pos)
			var height_diff: float = new_height - old_height

			# Calculate sediment capacity
			var slope: float = max(-height_diff, min_slope)
			var capacity: float = max(slope, min_slope) * speed * water * capacity_mult

			if sediment > capacity or height_diff > 0:
				# Deposit sediment
				var deposit_amount: float
				if height_diff > 0:
					# Deposit all sediment when going uphill
					deposit_amount = min(sediment, height_diff)
				else:
					deposit_amount = (sediment - capacity) * deposition_rate

				sediment -= deposit_amount
				_deposit_sediment(pos, deposit_amount, erosion_radius)
			else:
				# Erode terrain
				var erode_amount: float = min((capacity - sediment) * erosion_rate, -height_diff)
				sediment += _erode_terrain(pos, erode_amount, erosion_radius)

			# Update droplet
			speed = sqrt(max(0, speed * speed + height_diff))
			water *= (1.0 - evaporation)
			pos = new_pos

			if water < 0.01:
				break

	erosion_progress.emit(1.0)


func _calculate_gradient(pos: Vector2) -> Vector2:
	## Calculate terrain gradient at position using central differences
	var x: int = int(pos.x)
	var y: int = int(pos.y)

	if x < 1 or x >= terrain_size - 1 or y < 1 or y >= terrain_size - 1:
		return Vector2.ZERO

	var idx: int = y * terrain_size + x

	var gx: float = heightmap_data[idx + 1] - heightmap_data[idx - 1]
	var gy: float = heightmap_data[idx + terrain_size] - heightmap_data[idx - terrain_size]

	return Vector2(gx, gy) * 0.5


func _get_interpolated_height(pos: Vector2) -> float:
	## Bilinear interpolation for smooth height queries
	var x: int = int(pos.x)
	var y: int = int(pos.y)
	var fx: float = pos.x - x
	var fy: float = pos.y - y

	if x < 0 or x >= terrain_size - 1 or y < 0 or y >= terrain_size - 1:
		return 0.0

	var h00: float = heightmap_data[y * terrain_size + x]
	var h10: float = heightmap_data[y * terrain_size + x + 1]
	var h01: float = heightmap_data[(y + 1) * terrain_size + x]
	var h11: float = heightmap_data[(y + 1) * terrain_size + x + 1]

	var h0: float = lerp(h00, h10, fx)
	var h1: float = lerp(h01, h11, fx)

	return lerp(h0, h1, fy)


func _deposit_sediment(pos: Vector2, amount: float, radius: int) -> void:
	## Deposit sediment in a circular area around position
	var x: int = int(pos.x)
	var y: int = int(pos.y)

	if radius <= 1:
		if x >= 0 and x < terrain_size and y >= 0 and y < terrain_size:
			heightmap_data[y * terrain_size + x] += amount
		return

	var total_weight: float = 0.0
	var weights: Array[float] = []
	var indices: Array[int] = []

	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var nx: int = x + dx
			var ny: int = y + dy

			if nx < 0 or nx >= terrain_size or ny < 0 or ny >= terrain_size:
				continue

			var dist: float = sqrt(dx * dx + dy * dy)
			if dist > radius:
				continue

			var weight: float = 1.0 - dist / float(radius)
			weights.append(weight)
			indices.append(ny * terrain_size + nx)
			total_weight += weight

	if total_weight > 0:
		for i in range(weights.size()):
			heightmap_data[indices[i]] += amount * weights[i] / total_weight


func _erode_terrain(pos: Vector2, amount: float, radius: int) -> float:
	## Erode terrain in a circular area, return actual sediment picked up
	var x: int = int(pos.x)
	var y: int = int(pos.y)

	if radius <= 1:
		if x >= 0 and x < terrain_size and y >= 0 and y < terrain_size:
			var idx: int = y * terrain_size + x
			var eroded: float = min(amount, heightmap_data[idx])
			heightmap_data[idx] -= eroded
			return eroded
		return 0.0

	var total_weight: float = 0.0
	var weights: Array[float] = []
	var indices: Array[int] = []

	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var nx: int = x + dx
			var ny: int = y + dy

			if nx < 0 or nx >= terrain_size or ny < 0 or ny >= terrain_size:
				continue

			var dist: float = sqrt(dx * dx + dy * dy)
			if dist > radius:
				continue

			var weight: float = 1.0 - dist / float(radius)
			weights.append(weight)
			indices.append(ny * terrain_size + nx)
			total_weight += weight

	var total_eroded: float = 0.0
	if total_weight > 0:
		for i in range(weights.size()):
			var erode_here: float = amount * weights[i] / total_weight
			var actual: float = min(erode_here, heightmap_data[indices[i]])
			heightmap_data[indices[i]] -= actual
			total_eroded += actual

	return total_eroded


func _normalize_heightmap() -> void:
	## Normalize heightmap to 0-1 range
	var min_h: float = 1.0
	var max_h: float = 0.0

	for h in heightmap_data:
		min_h = min(min_h, h)
		max_h = max(max_h, h)

	var range_h: float = max_h - min_h
	if range_h < 0.001:
		range_h = 1.0

	for i in range(heightmap_data.size()):
		heightmap_data[i] = (heightmap_data[i] - min_h) / range_h


func _create_heightmap_image() -> void:
	heightmap = Image.create(terrain_size, terrain_size, false, Image.FORMAT_RF)

	for y in range(terrain_size):
		for x in range(terrain_size):
			var h: float = heightmap_data[y * terrain_size + x]
			heightmap.set_pixel(x, y, Color(h, h, h, 1.0))


## Get height at world position
func get_height_at(world_pos: Vector3) -> float:
	var fx: float = world_pos.x / cell_size
	var fz: float = world_pos.z / cell_size

	var x: int = int(fx)
	var z: int = int(fz)

	if x < 0 or x >= terrain_size - 1 or z < 0 or z >= terrain_size - 1:
		return 0.0

	# Bilinear interpolation
	var dx: float = fx - x
	var dz: float = fz - z

	var h00: float = heightmap_data[z * terrain_size + x]
	var h10: float = heightmap_data[z * terrain_size + x + 1]
	var h01: float = heightmap_data[(z + 1) * terrain_size + x]
	var h11: float = heightmap_data[(z + 1) * terrain_size + x + 1]

	var h0: float = lerp(h00, h10, dx)
	var h1: float = lerp(h01, h11, dx)

	return lerp(h0, h1, dz) * height_scale


## Get normal at world position
func get_normal_at(world_pos: Vector3) -> Vector3:
	var delta: float = cell_size

	var hL: float = get_height_at(world_pos + Vector3(-delta, 0, 0))
	var hR: float = get_height_at(world_pos + Vector3(delta, 0, 0))
	var hD: float = get_height_at(world_pos + Vector3(0, 0, -delta))
	var hU: float = get_height_at(world_pos + Vector3(0, 0, delta))

	return Vector3(hL - hR, 2.0 * delta, hD - hU).normalized()


## Modify heightmap in a region (for damage/clearing)
func modify_region(center: Vector2i, radius: int, modifier: Callable) -> void:
	var affected := Rect2i(
		Vector2i(max(0, center.x - radius), max(0, center.y - radius)),
		Vector2i(min(terrain_size, center.x + radius) - max(0, center.x - radius),
				 min(terrain_size, center.y + radius) - max(0, center.y - radius))
	)

	for y in range(affected.position.y, affected.position.y + affected.size.y):
		for x in range(affected.position.x, affected.position.x + affected.size.x):
			var dist: float = Vector2(x - center.x, y - center.y).length()
			if dist <= radius:
				var idx: int = y * terrain_size + x
				var falloff: float = 1.0 - smoothstep(0.0, float(radius), dist)
				heightmap_data[idx] = modifier.call(heightmap_data[idx], falloff)

	# Update image
	for y in range(affected.position.y, affected.position.y + affected.size.y):
		for x in range(affected.position.x, affected.position.x + affected.size.x):
			var h: float = heightmap_data[y * terrain_size + x]
			heightmap.set_pixel(x, y, Color(h, h, h, 1.0))

	terrain_updated.emit(affected)
