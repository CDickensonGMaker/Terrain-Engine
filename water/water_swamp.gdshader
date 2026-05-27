shader_type spatial;
render_mode depth_draw_always, cull_disabled;

// Include shared water utilities
#include "res://water/water_common.gdshaderinc"

// Swamp colors - murky brown-green, less transparent
uniform vec4 water_color : source_color = vec4(0.18, 0.20, 0.12, 0.82);
uniform vec4 water_color_deep : source_color = vec4(0.10, 0.12, 0.06, 0.92);
uniform float depth_fade : hint_range(0.1, 10.0) = 1.5;

// Shore blending (faster fade - swamps have soft edges)
uniform float shore_fade_distance : hint_range(0.5, 5.0) = 4.0;

// Specular (lower - murky water has less reflectivity)
uniform float specular_strength : hint_range(0.0, 1.0) = 0.15;
uniform float specular_shininess : hint_range(1.0, 128.0) = 8.0;

// Very slow ripples (stagnant water)
uniform float ripple_strength : hint_range(0.0, 0.05) = 0.008;
uniform float ripple_scale : hint_range(1.0, 30.0) = 12.0;
uniform float ripple_speed : hint_range(0.1, 2.0) = 0.25;

// Muck/algae overlay
uniform float muck_intensity : hint_range(0.0, 1.0) = 0.4;
uniform vec4 muck_color : source_color = vec4(0.25, 0.30, 0.10, 1.0);
uniform float muck_scale : hint_range(0.01, 0.2) = 0.03;

// Shore distance from vertex color (R channel)
varying float v_shore_distance;
varying vec2 v_world_uv;

// Simple noise for muck pattern
float swamp_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = fract(sin(dot(i, vec2(127.1, 311.7))) * 43758.5453);
	float b = fract(sin(dot(i + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5453);
	float c = fract(sin(dot(i + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	float d = fract(sin(dot(i + vec2(1.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	// Shore distance stored in vertex color R channel
	v_shore_distance = COLOR.r * 10.0;

	// World-space UV for consistent patterns
	v_world_uv = VERTEX.xz;
}

void fragment() {
	vec2 scaled_uv = v_world_uv * 0.05;

	// Very slow, subtle ripples (stagnant water)
	float ripple = water_ripple(scaled_uv, ripple_scale, ripple_speed, TIME);
	float ripple2 = water_ripple(scaled_uv * 0.5 + vec2(0.5, 0.25), ripple_scale * 0.8, ripple_speed * 0.6, TIME);
	float combined_ripple = (ripple + ripple2) * 0.5;

	// Generate subtle normal variation
	vec3 normal = water_normal_from_height(scaled_uv, ripple_scale, ripple_speed, TIME, ripple_strength * 4.0);

	// Depth-based color (shallow = lighter, deeper = darker)
	float depth_factor = clamp(v_shore_distance / shore_fade_distance, 0.0, 1.0);
	vec4 base_color = water_color_by_depth(water_color, water_color_deep, depth_factor, 1.0);

	// Muck/algae overlay - patchy coverage
	float muck_noise = swamp_noise(v_world_uv * muck_scale);
	float muck_noise2 = swamp_noise(v_world_uv * muck_scale * 2.3 + vec2(50.0, 30.0));
	float muck_factor = smoothstep(0.4, 0.7, muck_noise * muck_noise2 * 2.0) * muck_intensity;

	// Apply muck in shallower areas more heavily
	muck_factor *= (1.0 - depth_factor * 0.5);

	// Blend muck into base color
	vec3 final_rgb = mix(base_color.rgb, muck_color.rgb, muck_factor);

	// Add very subtle ripple variation
	final_rgb += vec3(combined_ripple * 0.015 - 0.0075);

	// Shore blending - wider fade for swamp edges
	float shore_blend = water_shore_blend(v_shore_distance, shore_fade_distance);
	float final_alpha = base_color.a * shore_blend;

	// Reduce alpha where muck is present (looks more solid)
	final_alpha = mix(final_alpha, 0.95, muck_factor * 0.3);

	ALBEDO = final_rgb;
	ALPHA = final_alpha;

	// Subtle normal mapping
	NORMAL_MAP = normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.2;

	// Low specular - murky water doesn't shine much
	ROUGHNESS = 1.0 - specular_strength * 0.5;
	SPECULAR = specular_strength * 0.4;
	METALLIC = 0.0;
}
