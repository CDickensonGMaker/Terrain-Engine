extends Node3D
class_name FogOfWar
## Fog of War system for RTS games
## Uses a texture-based approach with shader rendering
## Supports: unexplored, explored (shroud), and visible states

signal fog_updated(region: Rect2i)
signal area_revealed(position: Vector3, radius: float)

# Fog states
enum FogState {
	UNEXPLORED,  # Never seen (black)
	SHROUD,      # Previously seen (dark, shows terrain but not units)
	VISIBLE,     # Currently visible (clear)
}

# Configuration
@export var map_size: float = 1000.0  # World units
@export var texture_size: int = 256   # Resolution of fog texture
@export var blur_passes: int = 2      # Smoothing passes
@export var shroud_alpha: float = 0.5 # How dark shroud appears (0-1)
@export var unexplored_alpha: float = 0.95  # How dark unexplored appears

# Fog data
var fog_texture: Image           # Current visibility (0 = visible, 1 = fog)
var explored_texture: Image      # What's been explored (0 = explored, 1 = unexplored)
var fog_image_texture: ImageTexture
var explored_image_texture: ImageTexture

# Visibility sources (units, buildings with sight)
var visibility_sources: Array[Dictionary] = []  # {id, position, radius, active}
var next_source_id: int = 0

# Update throttling
var update_timer: float = 0.0
var update_interval: float = 0.1  # Update 10x per second

# Rendering
var fog_mesh: MeshInstance3D
var fog_material: ShaderMaterial

# Cell size for world-to-texture conversion
var cell_size: float


func _ready() -> void:
	cell_size = map_size / float(texture_size)
	_init_textures()
	_create_fog_mesh()


func _init_textures() -> void:
	# Fog texture: R channel = current visibility (0=visible, 1=fogged)
	fog_texture = Image.create(texture_size, texture_size, false, Image.FORMAT_RF)
	fog_texture.fill(Color(1, 0, 0, 1))  # Start fully fogged

	# Explored texture: R channel = exploration state (0=explored, 1=unexplored)
	explored_texture = Image.create(texture_size, texture_size, false, Image.FORMAT_RF)
	explored_texture.fill(Color(1, 0, 0, 1))  # Start fully unexplored

	fog_image_texture = ImageTexture.create_from_image(fog_texture)
	explored_image_texture = ImageTexture.create_from_image(explored_texture)


func _create_fog_mesh() -> void:
	# Create a plane mesh that covers the entire map
	var plane := PlaneMesh.new()
	plane.size = Vector2(map_size, map_size)
	plane.subdivide_width = 1
	plane.subdivide_depth = 1

	fog_mesh = MeshInstance3D.new()
	fog_mesh.mesh = plane
	fog_mesh.position = Vector3(map_size / 2.0, 0, map_size / 2.0)  # Center on map

	# Create shader material
	fog_material = ShaderMaterial.new()
	fog_material.shader = _create_fog_shader()
	fog_material.set_shader_parameter("fog_texture", fog_image_texture)
	fog_material.set_shader_parameter("explored_texture", explored_image_texture)
	fog_material.set_shader_parameter("shroud_alpha", shroud_alpha)
	fog_material.set_shader_parameter("unexplored_alpha", unexplored_alpha)
	fog_material.set_shader_parameter("fog_color", Color(0.02, 0.02, 0.05, 1.0))

	fog_mesh.material_override = fog_material
	fog_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	add_child(fog_mesh)


func _create_fog_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_opaque, cull_disabled;

uniform sampler2D fog_texture : filter_linear;
uniform sampler2D explored_texture : filter_linear;
uniform float shroud_alpha : hint_range(0.0, 1.0) = 0.5;
uniform float unexplored_alpha : hint_range(0.0, 1.0) = 0.95;
uniform vec4 fog_color : source_color = vec4(0.02, 0.02, 0.05, 1.0);

varying vec2 world_uv;

void vertex() {
	// Calculate UV from world position
	world_uv = (VERTEX.xz + vec2(0.5)) / vec2(1.0);
}

void fragment() {
	// Sample fog textures
	float fog_value = texture(fog_texture, world_uv).r;
	float explored_value = texture(explored_texture, world_uv).r;

	// Calculate final alpha
	// If unexplored: full fog
	// If explored but not visible: shroud
	// If visible: transparent
	float alpha = 0.0;

	if (explored_value > 0.5) {
		// Unexplored
		alpha = unexplored_alpha;
	} else if (fog_value > 0.5) {
		// Explored but currently fogged (shroud)
		alpha = shroud_alpha * fog_value;
	} else {
		// Visible - fade based on fog value
		alpha = shroud_alpha * fog_value;
	}

	ALBEDO = fog_color.rgb;
	ALPHA = alpha;
}
"""
	return shader


func _process(delta: float) -> void:
	update_timer += delta
	if update_timer >= update_interval:
		update_timer = 0.0
		_update_fog()


func _update_fog() -> void:
	# Reset fog to fully fogged
	fog_texture.fill(Color(1, 0, 0, 1))

	# Reveal areas around each visibility source
	for source in visibility_sources:
		if source.active:
			_reveal_circle(source.position, source.radius, false)

	# Apply blur for smooth edges
	for i in range(blur_passes):
		_blur_texture(fog_texture)

	# Update GPU texture
	fog_image_texture.update(fog_texture)


func _reveal_circle(world_pos: Vector3, radius: float, permanent: bool) -> void:
	var center := _world_to_texture(world_pos)
	var tex_radius: int = int(radius / cell_size)

	for y in range(max(0, center.y - tex_radius), min(texture_size, center.y + tex_radius + 1)):
		for x in range(max(0, center.x - tex_radius), min(texture_size, center.x + tex_radius + 1)):
			var dist: float = Vector2(x - center.x, y - center.y).length()
			if dist <= tex_radius:
				# Smooth falloff at edges
				var falloff: float = 1.0 - smoothstep(tex_radius * 0.7, float(tex_radius), dist)

				# Update fog (current visibility)
				var current_fog: float = fog_texture.get_pixel(x, y).r
				var new_fog: float = min(current_fog, 1.0 - falloff)
				fog_texture.set_pixel(x, y, Color(new_fog, 0, 0, 1))

				# Update explored (permanent)
				if falloff > 0.3:
					var current_explored: float = explored_texture.get_pixel(x, y).r
					if current_explored > 0.5:
						explored_texture.set_pixel(x, y, Color(0, 0, 0, 1))

	# Update explored texture on GPU
	explored_image_texture.update(explored_texture)


func _blur_texture(img: Image) -> void:
	# Simple 3x3 box blur
	var temp := Image.create(texture_size, texture_size, false, Image.FORMAT_RF)

	for y in range(1, texture_size - 1):
		for x in range(1, texture_size - 1):
			var sum: float = 0.0
			for ky in range(-1, 2):
				for kx in range(-1, 2):
					sum += img.get_pixel(x + kx, y + ky).r
			temp.set_pixel(x, y, Color(sum / 9.0, 0, 0, 1))

	# Copy back
	for y in range(1, texture_size - 1):
		for x in range(1, texture_size - 1):
			img.set_pixel(x, y, temp.get_pixel(x, y))


func _world_to_texture(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		clampi(int(world_pos.x / cell_size), 0, texture_size - 1),
		clampi(int(world_pos.z / cell_size), 0, texture_size - 1)
	)


# ============================================================================
# PUBLIC API
# ============================================================================

## Register a visibility source (unit, building)
func register_source(position: Vector3, sight_radius: float) -> int:
	var source_id: int = next_source_id
	next_source_id += 1

	visibility_sources.append({
		"id": source_id,
		"position": position,
		"radius": sight_radius,
		"active": true,
	})

	return source_id


## Update source position (call each frame for moving units)
func update_source_position(source_id: int, position: Vector3) -> void:
	for source in visibility_sources:
		if source.id == source_id:
			source.position = position
			return


## Update source sight radius
func update_source_radius(source_id: int, radius: float) -> void:
	for source in visibility_sources:
		if source.id == source_id:
			source.radius = radius
			return


## Deactivate source (unit died, building destroyed)
func deactivate_source(source_id: int) -> void:
	for source in visibility_sources:
		if source.id == source_id:
			source.active = false
			return


## Reactivate source
func activate_source(source_id: int) -> void:
	for source in visibility_sources:
		if source.id == source_id:
			source.active = true
			return


## Remove source completely
func remove_source(source_id: int) -> void:
	for i in range(visibility_sources.size() - 1, -1, -1):
		if visibility_sources[i].id == source_id:
			visibility_sources.remove_at(i)
			return


## Permanently reveal an area (for cleared jungle, etc.)
func reveal_area_permanent(position: Vector3, radius: float) -> void:
	_reveal_circle(position, radius, true)
	# Also mark as explored
	var center := _world_to_texture(position)
	var tex_radius: int = int(radius / cell_size)

	for y in range(max(0, center.y - tex_radius), min(texture_size, center.y + tex_radius + 1)):
		for x in range(max(0, center.x - tex_radius), min(texture_size, center.x + tex_radius + 1)):
			var dist: float = Vector2(x - center.x, y - center.y).length()
			if dist <= tex_radius:
				explored_texture.set_pixel(x, y, Color(0, 0, 0, 1))

	explored_image_texture.update(explored_texture)
	area_revealed.emit(position, radius)


## Check if a position is currently visible (renamed to avoid Node3D conflict)
func is_position_visible(world_pos: Vector3) -> bool:
	var tex_pos := _world_to_texture(world_pos)
	return fog_texture.get_pixel(tex_pos.x, tex_pos.y).r < 0.5


## Check if a position has been explored
func is_position_explored(world_pos: Vector3) -> bool:
	var tex_pos := _world_to_texture(world_pos)
	return explored_texture.get_pixel(tex_pos.x, tex_pos.y).r < 0.5


## Get fog state at position
func get_fog_state(world_pos: Vector3) -> FogState:
	var tex_pos := _world_to_texture(world_pos)
	var explored: float = explored_texture.get_pixel(tex_pos.x, tex_pos.y).r
	var fog: float = fog_texture.get_pixel(tex_pos.x, tex_pos.y).r

	if explored > 0.5:
		return FogState.UNEXPLORED
	elif fog > 0.5:
		return FogState.SHROUD
	else:
		return FogState.VISIBLE


## Set fog height (Y position of fog plane)
func set_fog_height(height: float) -> void:
	fog_mesh.position.y = height


## Toggle fog visibility (for debugging)
func set_fog_visible(visible: bool) -> void:
	fog_mesh.visible = visible


## Reset fog to fully unexplored
func reset_fog() -> void:
	fog_texture.fill(Color(1, 0, 0, 1))
	explored_texture.fill(Color(1, 0, 0, 1))
	fog_image_texture.update(fog_texture)
	explored_image_texture.update(explored_texture)
	visibility_sources.clear()


## Reveal entire map (for debugging or game end)
func reveal_all() -> void:
	fog_texture.fill(Color(0, 0, 0, 1))
	explored_texture.fill(Color(0, 0, 0, 1))
	fog_image_texture.update(fog_texture)
	explored_image_texture.update(explored_texture)
