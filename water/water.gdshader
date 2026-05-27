shader_type spatial;
render_mode depth_draw_always, cull_disabled;

// Include shared water utilities
#include "res://water/water_common.gdshaderinc"

// Flow control
uniform float flow_speed : hint_range(0.01, 1.0) = 0.15;
uniform vec2 flow_direction = vec2(1.0, 0.0);

// Water appearance
uniform vec4 water_color : source_color = vec4(0.25, 0.32, 0.18, 0.7); // Murky green-brown
uniform vec4 water_color_deep : source_color = vec4(0.15, 0.20, 0.10, 0.85); // Deeper areas
uniform float depth_fade : hint_range(0.1, 10.0) = 2.0;

// Shore blending
uniform float shore_fade_distance : hint_range(0.5, 5.0) = 2.0;

// Specular
uniform float specular_strength : hint_range(0.0, 1.0) = 0.4;
uniform float specular_shininess : hint_range(1.0, 128.0) = 32.0;

// Wave distortion
uniform float wave_strength : hint_range(0.0, 0.1) = 0.02;
uniform float wave_scale : hint_range(1.0, 50.0) = 10.0;
uniform float wave_speed : hint_range(0.1, 5.0) = 1.5;

// Optional normal map
uniform sampler2D normal_map : hint_normal;
uniform bool use_normal_map = false;

// Shore distance from vertex color (R channel)
varying float v_shore_distance;

void vertex() {
	// Shore distance stored in vertex color R channel (set during mesh generation)
	v_shore_distance = COLOR.r * 10.0;  // Scale factor: 0-1 maps to 0-10 meters
}

void fragment() {
	// Scrolling UV for flow effect (using shared function)
	vec2 flow_uv1, flow_uv2;
	water_flow_uvs(UV, flow_direction, flow_speed, TIME, flow_uv1, flow_uv2);

	// Wave/ripple pattern using shared function
	float wave = water_ripple(UV, wave_scale, wave_speed, TIME);
	vec2 distorted_uv = flow_uv1 + vec2(wave * wave_strength, wave * wave_strength * 0.5);

	// Generate procedural normal from waves using shared function
	vec3 procedural_normal = water_normal_from_height(UV, wave_scale, wave_speed, TIME, wave_strength * 10.0);

	// Use normal map if provided, otherwise use procedural
	vec3 normal;
	if (use_normal_map) {
		vec3 normal_sample1 = texture(normal_map, distorted_uv).rgb * 2.0 - 1.0;
		vec3 normal_sample2 = texture(normal_map, flow_uv2).rgb * 2.0 - 1.0;
		normal = water_flow_blend(normal_sample1, normal_sample2);
	} else {
		normal = procedural_normal;
	}

	// Depth-based color mixing
	float depth_factor = clamp(wave * 0.3 + 0.5, 0.0, 1.0);
	vec4 final_color = water_color_by_depth(water_color, water_color_deep, depth_factor, 1.0);

	// Shore blending - fade alpha near edges
	float shore_blend = water_shore_blend(v_shore_distance, shore_fade_distance);
	float final_alpha = final_color.a * shore_blend;

	// Apply color
	ALBEDO = final_color.rgb;
	ALPHA = final_alpha;

	// Normal mapping
	NORMAL_MAP = normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.5;

	// Specular/roughness for highlights
	ROUGHNESS = 1.0 - specular_strength;
	SPECULAR = specular_strength;
	METALLIC = 0.0;
}
