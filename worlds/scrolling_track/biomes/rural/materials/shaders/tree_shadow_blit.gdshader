shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Shared mask rendered once by TreeShadowEffect; its alpha is the coverage.
uniform sampler2D shadow_tex : filter_linear, repeat_disable;
uniform vec4 shadow_color : source_color = vec4(0.02, 0.04, 0.02, 0.5);
// One texel of the mask, for the soft edge.
uniform vec2 texel = vec2(0.00390625, 0.00390625);
uniform float softness = 1.0;

varying vec2 mask_uv;

void vertex() {
	// The quad is a unit PlaneMesh scaled to the mask's cell, and the mask is
	// rendered with the same axes, so the local position is the mask UV.
	mask_uv = VERTEX.xz + 0.5;
}

void fragment() {
	vec2 step_uv = texel * softness;
	float mask = texture(shadow_tex, mask_uv).a * 0.6;
	mask += texture(shadow_tex, mask_uv + vec2(step_uv.x, 0.0)).a * 0.1;
	mask += texture(shadow_tex, mask_uv - vec2(step_uv.x, 0.0)).a * 0.1;
	mask += texture(shadow_tex, mask_uv + vec2(0.0, step_uv.y)).a * 0.1;
	mask += texture(shadow_tex, mask_uv - vec2(0.0, step_uv.y)).a * 0.1;

	ALBEDO = shadow_color.rgb;
	ALPHA = mask * shadow_color.a;
}
