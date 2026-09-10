shader_type spatial;
render_mode cull_disabled, world_vertex_coords, shadows_disabled;

uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D wind_mask : source_color, filter_linear_mipmap, repeat_enable;

uniform float wind_strength : hint_range(0.0, 30.0) = 10.0;
uniform float wind_speed : hint_range(0.0, 20.0) = 6.0;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_mask_scale : hint_range(1.0, 1000.0) = 200.0;
uniform float wind_push : hint_range(0.0, 2.0) = 1.0;
uniform float wind_bend : hint_range(0.0, 1.57) = 0.15;

varying float wind_sample;

float sample_wind(vec3 leaf_origin) {
	vec2 dir = normalize(wind_direction);
	vec2 sample_pos = (leaf_origin.xz - TIME * wind_speed * dir) / wind_mask_scale;
	return texture(wind_mask, sample_pos).r;
}

vec3 rotate_around(vec3 v, vec3 axis, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

void vertex() {
	vec3 instance_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 leaf_axis = normalize((MODEL_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 leaf_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);

	wind_sample = sample_wind(instance_origin);

	vec2 wdir = normalize(wind_direction);
	vec3 wind_force = vec3(wdir.x, 0.0, wdir.y) * sin(wind_sample * 6.28318) * wind_strength;
	VERTEX += wind_force * wind_push;

	vec3 wind_dir = vec3(wind_force.x, 0.0, wind_force.z);
	float wind_len = length(wind_dir);
	if (wind_len > 0.001) {
		vec3 axis = cross(leaf_axis, normalize(wind_dir));
		float axis_len = length(axis);
		if (axis_len > 0.001) {
			axis = axis / axis_len;
			float angle = wind_bend * clamp(wind_len / wind_strength, 0.0, 1.0);
			vec3 offset = VERTEX - instance_origin;
			VERTEX = instance_origin + rotate_around(offset, axis, angle);

			vec3 world_normal = rotate_around(leaf_normal, axis, angle);
			NORMAL = normalize((inverse(MODEL_MATRIX) * vec4(world_normal, 0.0)).xyz);
		}
	}
}

void fragment() {
	vec4 alb_full = texture(texture_albedo, UV);
	ALBEDO = albedo.rgb * alb_full.rgb;
	//ALPHA = alb_full.w;
	//ALPHA_SCISSOR_THRESHOLD = 0.5;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	//ALBEDO = vec3(float(FRONT_FACING));
}
