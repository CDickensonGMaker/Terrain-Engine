extends Node
## Damage System - Physical terrain deformation from explosions, bombardment, etc.
## Creates craters, scarring, and persistent damage markers using Decals

signal damage_applied(position: Vector3, type: DamageType, radius: float)
signal terrain_scarred(region: Rect2i)

enum DamageType {
	SMALL_EXPLOSION,    # Grenade, mortar - small crater
	MEDIUM_EXPLOSION,   # Artillery shell - medium crater
	LARGE_EXPLOSION,    # Bomb, large artillery - big crater
	NAPALM,             # Burns + slight depression
	BUNKER_COLLAPSE,    # Localized depression
}

# Damage profiles
const DAMAGE_PROFILES: Dictionary = {
	DamageType.SMALL_EXPLOSION: {
		"radius_cells": 3,
		"depth": 0.015,         # Normalized depth (0-1 scale)
		"rim_height": 0.005,    # Raised rim around crater
		"falloff_power": 2.0,
		"scar_color": Color(0.2, 0.15, 0.1),  # Dark brown
		"scar_type": "crater",
	},
	DamageType.MEDIUM_EXPLOSION: {
		"radius_cells": 6,
		"depth": 0.035,
		"rim_height": 0.012,
		"falloff_power": 1.8,
		"scar_color": Color(0.25, 0.18, 0.1),
		"scar_type": "crater",
	},
	DamageType.LARGE_EXPLOSION: {
		"radius_cells": 12,
		"depth": 0.06,
		"rim_height": 0.02,
		"falloff_power": 1.5,
		"scar_color": Color(0.3, 0.2, 0.12),
		"scar_type": "crater",
	},
	DamageType.NAPALM: {
		"radius_cells": 15,
		"depth": 0.01,
		"rim_height": 0.0,
		"falloff_power": 3.0,
		"scar_color": Color(0.05, 0.03, 0.02),  # Charred black
		"scar_type": "burn",
	},
	DamageType.BUNKER_COLLAPSE: {
		"radius_cells": 8,
		"depth": 0.05,
		"rim_height": 0.025,
		"falloff_power": 2.5,
		"scar_color": Color(0.4, 0.32, 0.22),
		"scar_type": "crater",
	},
}

# Damage tracking
var damage_zones: Array[Dictionary] = []
var scar_decals: Array[Decal] = []

# Reference to terrain manager (set by terrain_lab)
var terrain_manager: Node
var vegetation_manager: Node
var billboard_vegetation: Node

# Decal container node
var decal_container: Node3D

# Scar textures (procedurally generated)
var crater_scar_texture: ImageTexture
var burn_scar_texture: ImageTexture

# Texture size for scar decals
const SCAR_TEXTURE_SIZE: int = 128


func _ready() -> void:
	decal_container = Node3D.new()
	decal_container.name = "ScarDecals"
	add_child(decal_container)
	_create_scar_textures()


## Set terrain manager reference (called by terrain_lab)
func set_terrain_manager(manager: Node) -> void:
	terrain_manager = manager


## Set vegetation manager reference for clearing vegetation on damage
func set_vegetation_manager(veg_manager: Node) -> void:
	vegetation_manager = veg_manager


## Set billboard vegetation reference for clearing billboards on damage
func set_billboard_vegetation(billboard_veg: Node) -> void:
	billboard_vegetation = billboard_veg


## Apply damage at world position
func apply_damage(world_pos: Vector3, type: DamageType, intensity: float = 1.0) -> void:
	if not terrain_manager:
		push_warning("DamageSystem: TerrainManager not set - call set_terrain_manager()")
		return

	var profile: Dictionary = DAMAGE_PROFILES[type]
	var radius: int = int(profile.radius_cells * intensity)
	var depth: float = profile.depth * intensity
	var rim_height: float = profile.rim_height * intensity
	var falloff_power: float = profile.falloff_power

	# Create crater modifier function
	var crater_func := func(current_height: float, falloff_amount: float) -> float:
		# Crater shape: depression in center, rim at edge
		var rim_dist: float = 1.0 - falloff_amount  # Distance from center (0-1)

		# Crater profile
		var crater_depth: float = 0.0
		if rim_dist < 0.7:
			# Inside crater - depression
			var inner_falloff: float = pow(1.0 - rim_dist / 0.7, falloff_power)
			crater_depth = -depth * inner_falloff
		else:
			# Rim zone - slight rise
			var rim_falloff: float = 1.0 - (rim_dist - 0.7) / 0.3
			crater_depth = rim_height * rim_falloff

		return clampf(current_height + crater_depth, 0.0, 1.0)

	# Get cell size from terrain manager
	var cell_size: float = terrain_manager.cell_size
	var radius_meters: float = radius * cell_size

	# Apply to terrain manager's heightmap (this also rebuilds affected chunks)
	terrain_manager.modify_terrain(world_pos, radius_meters, crater_func)

	# Clear vegetation in damaged area. Pass heightmap so clear_area re-materializes
	# the surviving (non-cleared) bundles; otherwise the MultiMesh stays wiped.
	if vegetation_manager and vegetation_manager.has_method("clear_area"):
		vegetation_manager.clear_area(
			world_pos,
			radius_meters,
			terrain_manager.chunk_size,
			terrain_manager.heightmap,
		)

	# Clear billboards in damaged area
	if billboard_vegetation and billboard_vegetation.has_method("clear_chunk"):
		# Get affected chunk coordinates
		var chunk_coord := Vector2i(
			int(floor(world_pos.x / terrain_manager.chunk_size)),
			int(floor(world_pos.z / terrain_manager.chunk_size))
		)
		# Regenerate billboard for this chunk (will respect cleared vegetation)
		if vegetation_manager and vegetation_manager._chunk_terrain.has(chunk_coord):
			billboard_vegetation.generate_for_chunk(
				chunk_coord,
				terrain_manager.heightmap,
				vegetation_manager._chunk_terrain[chunk_coord]
			)

	# Get terrain height at damage position for decal placement
	var terrain_height: float = terrain_manager.get_height_at(world_pos)

	# Record damage zone
	damage_zones.append({
		"position": world_pos,
		"type": type,
		"radius": radius_meters,
		"intensity": intensity,
		"time": Time.get_ticks_msec(),
	})

	# Create visible scar decal
	_create_scar_decal(
		Vector3(world_pos.x, terrain_height, world_pos.z),
		radius_meters,
		profile.scar_color,
		profile.scar_type,
		intensity
	)

	damage_applied.emit(world_pos, type, radius_meters)


## Create procedural scar textures for decals
func _create_scar_textures() -> void:
	# Create crater scar texture (circular with darker center, brown rim)
	var crater_img := Image.create(SCAR_TEXTURE_SIZE, SCAR_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var center := Vector2(SCAR_TEXTURE_SIZE / 2.0, SCAR_TEXTURE_SIZE / 2.0)
	var max_dist: float = SCAR_TEXTURE_SIZE / 2.0

	for y in range(SCAR_TEXTURE_SIZE):
		for x in range(SCAR_TEXTURE_SIZE):
			var pos := Vector2(x, y)
			var dist: float = pos.distance_to(center) / max_dist

			if dist > 1.0:
				crater_img.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				# Crater: dark center, brown rim, soft edge
				var edge_falloff: float = smoothstep(0.7, 1.0, dist)
				var center_darkness: float = 1.0 - dist * 0.5

				# Add some noise for variation
				var noise_val: float = sin(x * 0.3) * cos(y * 0.3) * 0.1

				var r: float = clampf(0.15 + dist * 0.15 + noise_val, 0.0, 1.0)
				var g: float = clampf(0.1 + dist * 0.1 + noise_val * 0.5, 0.0, 1.0)
				var b: float = clampf(0.05 + dist * 0.05, 0.0, 1.0)
				var a: float = (1.0 - edge_falloff) * center_darkness

				crater_img.set_pixel(x, y, Color(r, g, b, a))

	crater_scar_texture = ImageTexture.create_from_image(crater_img)

	# Create burn scar texture (charred black with irregular edges)
	var burn_img := Image.create(SCAR_TEXTURE_SIZE, SCAR_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)

	for y in range(SCAR_TEXTURE_SIZE):
		for x in range(SCAR_TEXTURE_SIZE):
			var pos := Vector2(x, y)
			var dist: float = pos.distance_to(center) / max_dist

			if dist > 1.0:
				burn_img.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				# Burn: very dark, charred look
				var edge_falloff: float = smoothstep(0.6, 1.0, dist)

				# Irregular noise pattern for burn marks
				var noise1: float = sin(x * 0.5 + y * 0.3) * 0.15
				var noise2: float = cos(x * 0.2 - y * 0.4) * 0.1
				var noise_combined: float = noise1 + noise2

				# Very dark charred colors
				var r: float = clampf(0.03 + noise_combined * 0.02, 0.0, 0.1)
				var g: float = clampf(0.02 + noise_combined * 0.01, 0.0, 0.08)
				var b: float = clampf(0.01, 0.0, 0.05)
				var a: float = (1.0 - edge_falloff) * 0.9

				burn_img.set_pixel(x, y, Color(r, g, b, a))

	burn_scar_texture = ImageTexture.create_from_image(burn_img)


## Create a decal at the damage position
func _create_scar_decal(position: Vector3, radius: float, color: Color, scar_type: String, intensity: float) -> void:
	var decal := Decal.new()
	decal.name = "ScarDecal_%d" % scar_decals.size()

	# Position decal at damage location, slightly above terrain
	decal.position = position + Vector3(0, 1, 0)

	# Size based on damage radius (decal size is half-extents, so multiply by 2)
	var decal_size: float = radius * 2.2 * intensity  # Slightly larger than crater
	decal.size = Vector3(decal_size, 10.0, decal_size)  # 10m height to project onto terrain

	# Select texture based on scar type
	if scar_type == "burn":
		decal.texture_albedo = burn_scar_texture
	else:
		decal.texture_albedo = crater_scar_texture

	# Decal settings
	decal.albedo_mix = 0.85 * intensity  # How much to blend with terrain
	decal.modulate = color  # Tint the texture
	decal.cull_mask = 1  # Only affect terrain layer
	decal.upper_fade = 0.1
	decal.lower_fade = 0.3

	# Random rotation for variety
	decal.rotation.y = randf() * TAU

	decal_container.add_child(decal)
	scar_decals.append(decal)


## Apply area bombardment (multiple craters)
func apply_bombardment(center: Vector3, radius: float, count: int, type: DamageType) -> void:
	for i in range(count):
		var angle: float = randf() * TAU
		var dist: float = randf() * radius
		var offset := Vector3(cos(angle) * dist, 0, sin(angle) * dist)
		var intensity: float = randf_range(0.7, 1.0)

		apply_damage(center + offset, type, intensity)


## Clear all damage (for testing reset)
func clear_all_damage() -> void:
	damage_zones.clear()

	# Remove all scar decals
	for decal in scar_decals:
		if is_instance_valid(decal):
			decal.queue_free()
	scar_decals.clear()

	terrain_scarred.emit(Rect2i(Vector2i.ZERO, Vector2i(256, 256)))


## Get damage count
func get_damage_count() -> int:
	return damage_zones.size()


## Get all damage zones (for saving/loading)
func get_damage_zones() -> Array[Dictionary]:
	return damage_zones
