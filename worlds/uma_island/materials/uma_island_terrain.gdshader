shader_type spatial;

// --- Layer 1: Sand (base) ---
uniform sampler2D sand_albedo : source_color, filter_linear_mipmap;
uniform sampler2D sand_roughness : hint_default_white, filter_linear_mipmap;
uniform sampler2D sand_normal : hint_normal;
uniform lowp vec2 sand_uv_scale = vec2(10.0);

// --- Layer 2: Dirt ---
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D dirt_roughness : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D dirt_normal : hint_normal;
uniform lowp vec2 dirt_uv_scale = vec2(8.0);

// --- Layer 3: Grass ---
uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D grass_roughness : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D grass_normal : hint_normal;
uniform lowp vec2 grass_uv_scale = vec2(6.0);

// --- Layer 4: Stone ---
uniform sampler2D stone_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D stone_roughness : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D stone_normal : hint_normal;
uniform lowp vec2 stone_uv_scale = vec2(4.0);

// --- Single splatmap (R=dirt, G=grass, B=stone) ---
uniform sampler2D splatmap : source_color, filter_linear_mipmap;

void vertex() {
}

void fragment() {
	vec4 splat = texture(splatmap, UV);
	float dirt_mask = splat.r;
	float grass_mask = splat.g;
	float stone_mask = splat.b;
	float sand_mask = 1.0 - clamp(dirt_mask + grass_mask + stone_mask, 0.0, 1.0);

	vec3 albedo = vec3(0.0);
	vec3 blended_normal = vec3(0.0);
	float rough = 0.0;
	float total_mask = 0.0;
	const float mask_eps = 0.005;

	if (sand_mask > mask_eps) {
		total_mask += sand_mask;
		albedo += texture(sand_albedo, UV * sand_uv_scale).rgb * sand_mask;
		rough += texture(sand_roughness, UV * sand_uv_scale).r * sand_mask;
		blended_normal += (texture(sand_normal, UV * sand_uv_scale).rgb * 2.0 - 1.0) * sand_mask;
	}
	if (dirt_mask > mask_eps) {
		total_mask += dirt_mask;
		albedo += texture(dirt_albedo, UV * dirt_uv_scale).rgb * dirt_mask;
		rough += texture(dirt_roughness, UV * dirt_uv_scale).r * dirt_mask;
		blended_normal += (texture(dirt_normal, UV * dirt_uv_scale).rgb * 2.0 - 1.0) * dirt_mask;
	}
	if (grass_mask > mask_eps) {
		total_mask += grass_mask;
		albedo += texture(grass_albedo, UV * grass_uv_scale).rgb * grass_mask;
		rough += texture(grass_roughness, UV * grass_uv_scale).r * grass_mask;
		blended_normal += (texture(grass_normal, UV * grass_uv_scale).rgb * 2.0 - 1.0) * grass_mask;
	}
	if (stone_mask > mask_eps) {
		total_mask += stone_mask;
		albedo += texture(stone_albedo, UV * stone_uv_scale).rgb * stone_mask;
		rough += texture(stone_roughness, UV * stone_uv_scale).r * stone_mask;
		blended_normal += (texture(stone_normal, UV * stone_uv_scale).rgb * 2.0 - 1.0) * stone_mask;
	}

	ALBEDO = albedo / total_mask;
	ROUGHNESS = rough / total_mask;

	blended_normal = normalize(blended_normal);
	NORMAL_MAP = blended_normal * 0.5 + 0.5;
}
