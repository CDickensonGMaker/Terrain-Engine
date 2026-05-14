extends Control
## Terrain Lab UI - Advanced controls for terrain generation testing

signal preset_changed(preset: int)
signal param_changed(param: String, value: Variant)
signal regenerate_requested
signal damage_mode_changed(type: int)
signal clearing_mode_changed(enabled: bool)

# Section containers (we'll build these dynamically)
var preset_dropdown: OptionButton
var seed_label: Label
var stats_label: Label
var damage_dropdown: OptionButton
var clearing_check: CheckButton

# Parameter sliders dictionary
var param_sliders: Dictionary = {}

var terrain_engine: Node
var damage_system: Node


func _ready() -> void:
	terrain_engine = get_node_or_null("/root/TerrainEngine")
	damage_system = get_node_or_null("/root/DamageSystem")

	_build_ui()
	_connect_signals()


func _build_ui() -> void:
	# Find UI elements from the scene tree
	preset_dropdown = $Panel/VBox/PresetSection/PresetDropdown
	seed_label = $Panel/VBox/SeedSection/SeedValue
	stats_label = $Panel/VBox/StatsSection/Stats
	damage_dropdown = $Panel/VBox/DamageSection/DamageDropdown
	clearing_check = $Panel/VBox/ClearingSection/ClearingToggle

	# Setup presets
	_setup_presets()
	_setup_damage_types()

	# Connect basic sliders
	_connect_slider("HeightScale", "height_scale", 50.0, 500.0, 280.0, "%.0f m")
	_connect_slider("BaseFreq", "base_frequency", 0.5, 10.0, 2.0, "%.3f", 0.001)
	_connect_slider("Smoothing", "smoothing_passes", 0, 5, 2, "%d")
	_connect_slider("Cliff", "cliff_sharpness", 0.5, 8.0, 3.0, "%.1f")

	# Advanced sliders (erosion section)
	_connect_slider("WarpStrength", "warp_strength", 0.0, 100.0, 40.0, "%.0f")
	_connect_slider("RidgeBlend", "ridge_blend", 0.0, 1.0, 0.4, "%.2f")
	_connect_slider("ErosionIter", "erosion_iterations", 0, 100000, 50000, "%.0fk", 0.001)

	# Connect toggles
	_connect_toggle("WarpEnabled", "warp_enabled", true)
	_connect_toggle("RidgeEnabled", "ridge_enabled", true)
	_connect_toggle("ErosionEnabled", "erosion_enabled", true)


func _connect_slider(node_name: String, param: String, min_val: float, max_val: float, default_val: float, format: String, multiplier: float = 1.0) -> void:
	var container := get_node_or_null("Panel/VBox/ParamSection/" + node_name)
	if not container:
		container = get_node_or_null("Panel/VBox/AdvancedSection/" + node_name)
	if not container:
		return

	var slider: HSlider = container.get_node_or_null("Slider")
	var value_label: Label = container.get_node_or_null("Value")

	if slider and value_label:
		param_sliders[param] = {
			"slider": slider,
			"label": value_label,
			"format": format,
			"multiplier": multiplier
		}

		slider.min_value = min_val
		slider.max_value = max_val
		slider.value = default_val

		var display_value: float = default_val * multiplier
		value_label.text = format % display_value

		slider.value_changed.connect(func(val: float):
			var real_val: float = val * multiplier
			value_label.text = format % (real_val if multiplier == 1.0 else val * multiplier)
			var emit_val: Variant = int(val) if ("passes" in param or "iterations" in param) else real_val
			param_changed.emit(param, emit_val)
		)


func _connect_toggle(node_name: String, param: String, default_val: bool) -> void:
	var toggle: CheckButton = get_node_or_null("Panel/VBox/AdvancedSection/" + node_name + "/Toggle")
	if toggle:
		toggle.button_pressed = default_val
		toggle.toggled.connect(func(pressed: bool):
			param_changed.emit(param, pressed)
		)


func _setup_presets() -> void:
	if not preset_dropdown:
		return

	preset_dropdown.clear()
	preset_dropdown.add_item("Rolling Hills", 0)
	preset_dropdown.add_item("Steep Mountains", 1)
	preset_dropdown.add_item("River Valley", 2)
	preset_dropdown.add_item("Coastal Hills", 3)
	preset_dropdown.add_item("Plateau", 4)
	preset_dropdown.add_item("Custom", 5)
	preset_dropdown.selected = 0


func _setup_damage_types() -> void:
	if not damage_dropdown:
		return

	damage_dropdown.clear()
	damage_dropdown.add_item("Small Explosion", 0)
	damage_dropdown.add_item("Medium Explosion", 1)
	damage_dropdown.add_item("Large Explosion", 2)
	damage_dropdown.add_item("Napalm", 3)
	damage_dropdown.add_item("Vehicle Tracks", 4)
	damage_dropdown.add_item("Bunker Collapse", 5)
	damage_dropdown.selected = 1


func _connect_signals() -> void:
	if preset_dropdown:
		preset_dropdown.item_selected.connect(_on_preset_selected)

	if damage_dropdown:
		damage_dropdown.item_selected.connect(_on_damage_type_selected)

	if clearing_check:
		clearing_check.toggled.connect(_on_clearing_toggled)

	if terrain_engine:
		terrain_engine.terrain_generated.connect(_on_terrain_generated)
		if terrain_engine.has_signal("erosion_progress"):
			terrain_engine.erosion_progress.connect(_on_erosion_progress)


func _on_preset_selected(index: int) -> void:
	preset_changed.emit(index)
	_update_sliders_from_preset(index)


func _update_sliders_from_preset(preset: int) -> void:
	if not terrain_engine:
		return

	if preset >= 5:  # Custom - don't update
		return

	# Get preset params
	var preset_params: Dictionary = terrain_engine.preset_params.get(preset, {})

	# Update each slider to match preset
	for param in param_sliders:
		if preset_params.has(param):
			var slider_data: Dictionary = param_sliders[param]
			var slider: HSlider = slider_data.slider
			var label: Label = slider_data.label
			var format_str: String = slider_data.format
			var mult: float = slider_data.multiplier

			var value: float = preset_params[param]
			if mult != 1.0:
				slider.set_value_no_signal(value / mult)
			else:
				slider.set_value_no_signal(value)

			label.text = format_str % value


func _on_damage_type_selected(index: int) -> void:
	damage_mode_changed.emit(index)


func _on_clearing_toggled(enabled: bool) -> void:
	clearing_mode_changed.emit(enabled)


func _on_terrain_generated(_heightmap: Image) -> void:
	if terrain_engine:
		seed_label.text = str(terrain_engine.seed_value)
		_update_stats()


func _on_erosion_progress(percent: float) -> void:
	if stats_label:
		stats_label.text = "Eroding... %.0f%%" % (percent * 100.0)


func _update_stats() -> void:
	if not terrain_engine:
		return

	var min_h: float = 1.0
	var max_h: float = 0.0
	var total: float = 0.0

	for h in terrain_engine.heightmap_data:
		min_h = min(min_h, h)
		max_h = max(max_h, h)
		total += h

	var avg_h: float = total / terrain_engine.heightmap_data.size()

	var height_scale: float = terrain_engine.height_scale
	stats_label.text = "Min: %.0fm  Max: %.0fm  Avg: %.0fm" % [
		min_h * height_scale,
		max_h * height_scale,
		avg_h * height_scale
	]


func _on_regenerate_pressed() -> void:
	regenerate_requested.emit()


func _on_reset_damage_pressed() -> void:
	if damage_system:
		damage_system.clear_all_damage()

	var clearing_system := get_node_or_null("/root/ClearingSystem")
	if clearing_system:
		clearing_system.clear_all_zones()


func get_selected_damage_type() -> int:
	if damage_dropdown:
		return damage_dropdown.selected
	return 1


func is_clearing_mode() -> bool:
	if clearing_check:
		return clearing_check.button_pressed
	return false
