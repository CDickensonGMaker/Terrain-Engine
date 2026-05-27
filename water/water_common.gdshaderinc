// water_common.gdshaderinc
// Shared utility functions for all water shaders in TerrainEngine
// Include with: #include "res://water/water_common.gdshaderinc"

// =============================================================================
// NOISE FUNCTIONS
// =============================================================================

// Fast hash function
float water_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Value noise
float water_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);  // Smoothstep

	float a = water_hash(i);
	float b = water_hash(i + vec2(1.0, 0.0));
	float c = water_hash(i + vec2(0.0, 1.0));
	float d = water_hash(i + vec2(1.0, 1.0));

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Fractal Brownian Motion
float water_fbm(vec2 p, int octaves) {
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;

	for (int i = 0; i < octaves; i++) {
		value += amplitude * water_noise(p * frequency);
		amplitude *= 0.5;
		frequency *= 2.0;
	}

	return value;
}

// =============================================================================
// WAVE FUNCTIONS
// =============================================================================

// Simple sine wave pattern
float water_wave(vec2 uv, vec2 direction, float scale, float speed, float time) {
	float phase = dot(uv * scale, direction) + time * speed;
	return sin(phase) * 0.5 + 0.5;
}

// Multi-directional ripple pattern (for static water)
float water_ripple(vec2 uv, float scale, float speed, float time) {
	float wave1 = sin(uv.x * scale + time * speed) * 0.5 + 0.5;
	float wave2 = sin(uv.y * scale * 0.7 + time * speed * 1.3) * 0.5 + 0.5;
	float wave3 = sin((uv.x + uv.y) * scale * 0.5 + time * speed * 0.8) * 0.5 + 0.5;
	return (wave1 + wave2 + wave3) / 3.0;
}

// Generate normal from height field
vec3 water_normal_from_height(vec2 uv, float scale, float speed, float time, float strength) {
	float delta = 0.01;

	float h_center = water_ripple(uv, scale, speed, time);
	float h_right = water_ripple(uv + vec2(delta, 0.0), scale, speed, time);
	float h_up = water_ripple(uv + vec2(0.0, delta), scale, speed, time);

	float dx = (h_right - h_center) * strength;
	float dy = (h_up - h_center) * strength;

	return normalize(vec3(-dx, -dy, 1.0));
}

// =============================================================================
// VIETNAM WATER COLORS
// =============================================================================

// Murky brown-green river water (Mekong style)
vec4 water_color_river() {
	return vec4(0.25, 0.32, 0.18, 0.75);
}

// Deeper river areas
vec4 water_color_river_deep() {
	return vec4(0.15, 0.20, 0.10, 0.85);
}

// Clear highland creek
vec4 water_color_creek() {
	return vec4(0.35, 0.45, 0.40, 0.65);
}

// Swamp water (dark, murky)
vec4 water_color_swamp() {
	return vec4(0.12, 0.18, 0.08, 0.90);
}

// Pond/lake (still, greenish)
vec4 water_color_pond() {
	return vec4(0.20, 0.30, 0.22, 0.80);
}

// Coastal ocean (blue-gray)
vec4 water_color_coastal() {
	return vec4(0.25, 0.35, 0.45, 0.85);
}

// Coastal shallow (near beach)
vec4 water_color_coastal_shallow() {
	return vec4(0.35, 0.50, 0.55, 0.70);
}

// Blend water colors based on depth
vec4 water_color_by_depth(vec4 shallow, vec4 deep, float depth, float fade_distance) {
	float t = clamp(depth / fade_distance, 0.0, 1.0);
	return mix(shallow, deep, t);
}

// =============================================================================
// SHORE BLENDING
// =============================================================================

// Calculate shore blend factor from distance to shore
// shore_distance: distance from shore in meters (0 = at shore)
// fade_distance: how far to fade (in meters)
float water_shore_blend(float shore_distance, float fade_distance) {
	return smoothstep(0.0, fade_distance, shore_distance);
}

// Apply shore fade to alpha
float water_shore_alpha(float base_alpha, float shore_distance, float fade_distance) {
	return base_alpha * water_shore_blend(shore_distance, fade_distance);
}

// =============================================================================
// FLOW UTILITIES
// =============================================================================

// Dual-layer flow UV for smooth animation
// Returns two UVs that can be blended for seamless flow
void water_flow_uvs(vec2 uv, vec2 flow_dir, float speed, float time, out vec2 uv1, out vec2 uv2) {
	uv1 = uv + flow_dir * time * speed;
	uv2 = uv + flow_dir * time * speed * 0.7 + vec2(0.37, 0.17);
}

// Blend two texture samples for flow
vec3 water_flow_blend(vec3 sample1, vec3 sample2) {
	return normalize(sample1 + sample2 - 1.0);
}

// =============================================================================
// FOAM
// =============================================================================

// Foam at shoreline based on depth
float water_shore_foam(float depth, float foam_threshold, float foam_width) {
	if (depth > foam_threshold) return 0.0;
	float foam_t = 1.0 - depth / foam_threshold;
	// Add noise for natural look
	return foam_t * foam_t;
}

// Foam at wave crests
float water_crest_foam(float wave_height, float foam_threshold) {
	if (wave_height < foam_threshold) return 0.0;
	return (wave_height - foam_threshold) / (1.0 - foam_threshold);
}

// =============================================================================
// SPECULAR
// =============================================================================

// Simple specular highlight
float water_specular(vec3 normal, vec3 view_dir, vec3 light_dir, float shininess) {
	vec3 half_dir = normalize(view_dir + light_dir);
	float spec_angle = max(dot(normal, half_dir), 0.0);
	return pow(spec_angle, shininess);
}
