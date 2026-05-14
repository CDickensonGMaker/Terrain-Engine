extends Node3D
class_name TerrainVFX
## Visual feedback for terrain operations - dust, explosions, construction markers
## Uses GPUParticles3D for performance

signal effect_started(effect_type: EffectType, position: Vector3)
signal effect_completed(effect_type: EffectType, position: Vector3)

enum EffectType {
	DUST_CLOUD,        # General dust kick-up
	EXPLOSION_SMALL,   # Grenade/mortar
	EXPLOSION_MEDIUM,  # Artillery
	EXPLOSION_LARGE,   # Bomb
	DIRT_SPRAY,        # Digging/trenching
	TREE_FALL,         # Jungle clearing
	CONSTRUCTION,      # Building marker
	NAPALM_FIRE,       # Burning effect
	DET_CORD_FLASH,    # Det cord detonation
}

# Effect configurations
const EFFECT_CONFIGS: Dictionary = {
	EffectType.DUST_CLOUD: {
		"amount": 50,
		"lifetime": 2.0,
		"emission_radius": 5.0,
		"color": Color(0.6, 0.5, 0.4, 0.6),
		"scale": Vector2(2.0, 4.0),
		"velocity": Vector3(0, 3, 0),
		"gravity": -1.0,
	},
	EffectType.EXPLOSION_SMALL: {
		"amount": 80,
		"lifetime": 1.5,
		"emission_radius": 3.0,
		"color": Color(1.0, 0.6, 0.2, 0.9),
		"scale": Vector2(1.0, 3.0),
		"velocity": Vector3(0, 8, 0),
		"gravity": -2.0,
		"flash": true,
	},
	EffectType.EXPLOSION_MEDIUM: {
		"amount": 150,
		"lifetime": 2.0,
		"emission_radius": 6.0,
		"color": Color(1.0, 0.5, 0.1, 0.95),
		"scale": Vector2(2.0, 5.0),
		"velocity": Vector3(0, 12, 0),
		"gravity": -3.0,
		"flash": true,
	},
	EffectType.EXPLOSION_LARGE: {
		"amount": 300,
		"lifetime": 3.0,
		"emission_radius": 12.0,
		"color": Color(1.0, 0.4, 0.0, 1.0),
		"scale": Vector2(3.0, 8.0),
		"velocity": Vector3(0, 18, 0),
		"gravity": -4.0,
		"flash": true,
		"shockwave": true,
	},
	EffectType.DIRT_SPRAY: {
		"amount": 40,
		"lifetime": 1.0,
		"emission_radius": 2.0,
		"color": Color(0.45, 0.35, 0.25, 0.8),
		"scale": Vector2(0.5, 1.5),
		"velocity": Vector3(0, 5, 0),
		"gravity": -8.0,
	},
	EffectType.TREE_FALL: {
		"amount": 60,
		"lifetime": 2.5,
		"emission_radius": 8.0,
		"color": Color(0.3, 0.5, 0.2, 0.7),
		"scale": Vector2(1.0, 2.0),
		"velocity": Vector3(0, 2, 0),
		"gravity": -1.5,
	},
	EffectType.CONSTRUCTION: {
		"amount": 20,
		"lifetime": 0.8,
		"emission_radius": 1.0,
		"color": Color(0.7, 0.6, 0.5, 0.5),
		"scale": Vector2(0.3, 0.8),
		"velocity": Vector3(0, 1, 0),
		"gravity": -2.0,
		"looping": true,
	},
	EffectType.NAPALM_FIRE: {
		"amount": 200,
		"lifetime": 4.0,
		"emission_radius": 15.0,
		"color": Color(1.0, 0.3, 0.0, 0.9),
		"scale": Vector2(2.0, 6.0),
		"velocity": Vector3(0, 6, 0),
		"gravity": -0.5,
		"looping": true,
	},
	EffectType.DET_CORD_FLASH: {
		"amount": 120,
		"lifetime": 0.8,
		"emission_radius": 4.0,
		"color": Color(1.0, 1.0, 0.8, 1.0),
		"scale": Vector2(1.0, 2.5),
		"velocity": Vector3(0, 15, 0),
		"gravity": -5.0,
		"flash": true,
	},
}

# Active particle systems (pooled for reuse)
var particle_pool: Array[GPUParticles3D] = []
var active_effects: Dictionary = {}  # effect_id -> GPUParticles3D
var next_effect_id: int = 0

# Shared materials
var smoke_material: ParticleProcessMaterial
var fire_material: ParticleProcessMaterial
var dirt_material: ParticleProcessMaterial
var flash_material: ParticleProcessMaterial

# Mesh for particles
var particle_mesh: QuadMesh


func _ready() -> void:
	_create_materials()
	_create_particle_pool(10)  # Pre-create 10 particle systems


func _create_materials() -> void:
	particle_mesh = QuadMesh.new()
	particle_mesh.size = Vector2(1, 1)

	# Smoke/dust material
	smoke_material = ParticleProcessMaterial.new()
	smoke_material.direction = Vector3(0, 1, 0)
	smoke_material.spread = 45.0
	smoke_material.initial_velocity_min = 2.0
	smoke_material.initial_velocity_max = 5.0
	smoke_material.gravity = Vector3(0, -1, 0)
	smoke_material.scale_min = 1.0
	smoke_material.scale_max = 3.0
	smoke_material.color = Color(0.6, 0.5, 0.4, 0.6)

	# Fire/explosion material
	fire_material = ParticleProcessMaterial.new()
	fire_material.direction = Vector3(0, 1, 0)
	fire_material.spread = 60.0
	fire_material.initial_velocity_min = 5.0
	fire_material.initial_velocity_max = 15.0
	fire_material.gravity = Vector3(0, -3, 0)
	fire_material.scale_min = 1.5
	fire_material.scale_max = 4.0
	fire_material.color = Color(1.0, 0.5, 0.1, 0.9)

	# Dirt spray material
	dirt_material = ParticleProcessMaterial.new()
	dirt_material.direction = Vector3(0, 1, 0)
	dirt_material.spread = 30.0
	dirt_material.initial_velocity_min = 3.0
	dirt_material.initial_velocity_max = 8.0
	dirt_material.gravity = Vector3(0, -10, 0)
	dirt_material.scale_min = 0.3
	dirt_material.scale_max = 1.0
	dirt_material.color = Color(0.45, 0.35, 0.25, 0.8)

	# Flash material (bright, short-lived)
	flash_material = ParticleProcessMaterial.new()
	flash_material.direction = Vector3(0, 1, 0)
	flash_material.spread = 180.0
	flash_material.initial_velocity_min = 10.0
	flash_material.initial_velocity_max = 20.0
	flash_material.gravity = Vector3(0, 0, 0)
	flash_material.scale_min = 2.0
	flash_material.scale_max = 5.0
	flash_material.color = Color(1.0, 1.0, 0.8, 1.0)


func _create_particle_pool(count: int) -> void:
	for i in range(count):
		var particles := GPUParticles3D.new()
		particles.emitting = false
		particles.one_shot = true
		particles.explosiveness = 0.8
		particles.draw_pass_1 = particle_mesh
		particles.process_material = smoke_material.duplicate()
		particles.visible = false
		add_child(particles)
		particle_pool.append(particles)


func _get_pooled_particles() -> GPUParticles3D:
	# Find inactive particles in pool
	for particles in particle_pool:
		if not particles.emitting:
			return particles

	# Create new if pool exhausted
	var particles := GPUParticles3D.new()
	particles.emitting = false
	particles.one_shot = true
	particles.explosiveness = 0.8
	particles.draw_pass_1 = particle_mesh
	particles.process_material = smoke_material.duplicate()
	add_child(particles)
	particle_pool.append(particles)
	return particles


## Play an effect at position
func play_effect(effect_type: EffectType, position: Vector3, scale_mult: float = 1.0) -> int:
	var config: Dictionary = EFFECT_CONFIGS[effect_type]
	var particles := _get_pooled_particles()

	# Configure particles
	particles.amount = int(config.amount * scale_mult)
	particles.lifetime = config.lifetime
	particles.one_shot = not config.get("looping", false)
	particles.explosiveness = 0.9 if config.get("flash", false) else 0.6

	# Configure material
	var mat: ParticleProcessMaterial = particles.process_material
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = config.emission_radius * scale_mult
	mat.direction = config.velocity.normalized()
	mat.initial_velocity_min = config.velocity.length() * 0.5
	mat.initial_velocity_max = config.velocity.length()
	mat.gravity = Vector3(0, config.gravity, 0)
	mat.scale_min = config.scale.x * scale_mult
	mat.scale_max = config.scale.y * scale_mult
	mat.color = config.color

	# Position and play
	particles.position = position
	particles.visible = true
	particles.restart()
	particles.emitting = true

	# Track effect
	var effect_id: int = next_effect_id
	next_effect_id += 1
	active_effects[effect_id] = particles

	effect_started.emit(effect_type, position)

	# Auto-cleanup for one-shot effects
	if particles.one_shot:
		get_tree().create_timer(config.lifetime + 0.5).timeout.connect(
			func(): _cleanup_effect(effect_id, effect_type, position)
		)

	# Add flash light for explosions
	if config.get("flash", false):
		_create_flash_light(position, config.emission_radius * 2 * scale_mult)

	return effect_id


## Stop a looping effect
func stop_effect(effect_id: int) -> void:
	if active_effects.has(effect_id):
		var particles: GPUParticles3D = active_effects[effect_id]
		particles.emitting = false
		active_effects.erase(effect_id)


func _cleanup_effect(effect_id: int, effect_type: EffectType, position: Vector3) -> void:
	if active_effects.has(effect_id):
		var particles: GPUParticles3D = active_effects[effect_id]
		particles.emitting = false
		particles.visible = false
		active_effects.erase(effect_id)
		effect_completed.emit(effect_type, position)


func _create_flash_light(position: Vector3, radius: float) -> void:
	var light := OmniLight3D.new()
	light.position = position + Vector3(0, 2, 0)
	light.light_color = Color(1.0, 0.8, 0.4)
	light.light_energy = 5.0
	light.omni_range = radius
	light.omni_attenuation = 2.0
	add_child(light)

	# Fade out
	var tween := create_tween()
	tween.tween_property(light, "light_energy", 0.0, 0.3)
	tween.tween_callback(light.queue_free)


# ============================================================================
# CONVENIENCE METHODS FOR TERRAIN OPERATIONS
# ============================================================================

## Play effect for damage type
func play_damage_effect(position: Vector3, damage_type: int) -> void:
	match damage_type:
		0:  # SMALL_EXPLOSION
			play_effect(EffectType.EXPLOSION_SMALL, position)
		1:  # MEDIUM_EXPLOSION
			play_effect(EffectType.EXPLOSION_MEDIUM, position)
		2:  # LARGE_EXPLOSION
			play_effect(EffectType.EXPLOSION_LARGE, position)
		3:  # NAPALM
			play_effect(EffectType.NAPALM_FIRE, position, 1.5)
		_:
			play_effect(EffectType.DUST_CLOUD, position)


## Play effect for engineering operation
func play_engineering_effect(position: Vector3, op_type: int) -> void:
	match op_type:
		0:  # CLEAR_JUNGLE
			play_effect(EffectType.TREE_FALL, position)
		1:  # FLATTEN_AREA
			play_effect(EffectType.DIRT_SPRAY, position, 2.0)
		2:  # DIG_TRENCH
			play_effect(EffectType.DIRT_SPRAY, position)
		3:  # BUILD_ROAD
			play_effect(EffectType.DIRT_SPRAY, position)
		4:  # CREATE_BERM
			play_effect(EffectType.DIRT_SPRAY, position, 1.5)
		5:  # DIG_FOXHOLE
			play_effect(EffectType.DIRT_SPRAY, position, 0.5)
		6:  # CRATER_BLAST
			play_effect(EffectType.EXPLOSION_MEDIUM, position)
		7:  # DET_CORD_LINE
			play_effect(EffectType.DET_CORD_FLASH, position)
		8:  # DET_CORD_SQUARE
			play_effect(EffectType.DET_CORD_FLASH, position, 1.5)
		_:
			play_effect(EffectType.DUST_CLOUD, position)


## Play multiple effects along a line (for linear operations)
func play_line_effect(effect_type: EffectType, start: Vector3, end: Vector3, spacing: float = 10.0) -> void:
	var direction: Vector3 = (end - start).normalized()
	var length: float = start.distance_to(end)
	var steps: int = int(length / spacing)

	for i in range(steps + 1):
		var t: float = float(i) / float(steps) if steps > 0 else 0.0
		var pos: Vector3 = start.lerp(end, t)
		# Stagger the effects slightly
		get_tree().create_timer(t * 0.2).timeout.connect(
			func(): play_effect(effect_type, pos, 0.8)
		)
