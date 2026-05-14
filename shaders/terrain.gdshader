shader_type spatial;

// Overlay textures for destruction
uniform sampler2D scar_texture : filter_linear, repeat_disable;
uniform sampler2D clearing_texture : filter_linear, repeat_disable;

// Terrain parameters
uniform float height_scale = 280.0;
uniform float cell_size = 4.0;
uniform int terrain_size = 769;

// Variation
uniform float color_noise_scale = 0.02;
uniform float color_noise_strength = 0.1;

varying vec3 world_pos;
varying vec3 vertex_normal;
varying vec3 v_color;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vertex_normal = NORMAL;
	v_color = COLOR.rgb;
}

void fragment() {
	// Use vertex color directly (computed per-vertex in terrain_chunk.gd)
	vec3 color = v_color;

	// Calculate slope for roughness
	float slope = 1.0 - abs(vertex_normal.y);
	slope = clamp(slope, 0.0, 1.0);

	// Add subtle noise variation
	vec2 noise_uv = world_pos.xz * color_noise_scale;
	float variation = noise(noise_uv) * 2.0 - 1.0;
	variation *= color_noise_strength;

	// UV for overlay textures (world-space mapping)
	vec2 uv = world_pos.xz / (float(terrain_size) * cell_size);
	uv = clamp(uv, 0.0, 1.0);

	// Apply clearing overlay (brown dirt where jungle is cleared)
	vec4 clearing = texture(clearing_texture, uv);
	color = mix(color, clearing.rgb, clearing.a);

	// Apply damage scars (craters, burns, etc.)
	vec4 scar = texture(scar_texture, uv);
	color = mix(color, scar.rgb, scar.a * 0.85);

	// Apply noise variation
	color += vec3(variation) * 0.3;
	color = clamp(color, vec3(0.0), vec3(1.0));

	ALBEDO = color;
	ROUGHNESS = mix(0.75, 0.95, slope);
}
