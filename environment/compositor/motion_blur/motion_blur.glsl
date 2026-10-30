// Single-file RenderingDevice shader for MotionBlurEffect. The editor's GLSL
// importer compiles every version below to SPIR-V; the effect picks one with
// RDShaderFile.get_spirv().
//
// Everything tuned at authoring time is a compile-time constant here, so the
// only per-frame inputs are the push-constant block and the reprojection
// matrices packed by MotionBlurUniforms.

#[versions]
default = "";
msaa = "#define USE_MSAA_DEPTH 1";
debug = "#define MB_DEBUG_BLUR 1";
debug_msaa = "#define MB_DEBUG_BLUR 1\n#define USE_MSAA_DEPTH 1";

#[vertex]
#version 450
layout(location = 0) out vec2 uv_interp;

void main() {
	const vec2 triangle[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
	vec2 in_pos = triangle[gl_VertexIndex];
	uv_interp = in_pos * 0.5 + 0.5;
	gl_Position = vec4(in_pos, 0.0, 1.0);
}

#[fragment]
#version 450
VERSION_DEFINES
layout(location = 0) in vec2 uv_interp;
layout(location = 0) out vec4 out_color;

// --- Semi-static parameters ------------------------------------------------

// Reject taps that land on a nearer surface (an occluder) instead of letting
// it bleed into the blur. Comment out to let the blur cross depth
// discontinuities: removes the fence-ground seam but lets occluders ghost.
// #define MB_DEPTH_REJECT 1

// Exposure as a shutter angle relative to the 1/60 s reprojection arc:
// 360 deg integrates the full arc, 180 deg half of it. 0 disables the blur.
const float MB_SHUTTER_ANGLE_DEG = 180.0;
// Number of taps along the exposure arc, including the current pixel.
// Must match MotionBlurUniforms.SAMPLE_COUNT.
const int MB_SAMPLE_COUNT = 4;
// Longest screen-space blur, in pixels.
const float MB_MAX_RADIUS_PX = 128.0;
// Minimum screen-space motion (pixels per 1/60 s exposure) that produces
// blur. Slower pixels fade smoothly to none; 0 disables the gate.
const float MB_MOTION_THRESHOLD_PX = 1.0;

// Matrices per view. Must match MotionBlurUniforms.MAX_REPROJECTION_STEPS.
const int MB_MAX_STEPS = 32;

// --- Inputs ----------------------------------------------------------------

layout(set = 0, binding = 0) uniform sampler2D color_tex;
#ifdef USE_MSAA_DEPTH
// With MSAA the mobile renderer never writes the resolved RB_TEX_DEPTH
// (depth resolve for compositor effects is unsupported), so read the
// multisampled depth attachment itself.
layout(set = 0, binding = 1) uniform sampler2DMS depth_tex;
#else
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
#endif

// One matrix per tap: maps this frame's clip position to the position the
// same world point had at an earlier point of the exposure. Interpolating the
// camera pose makes rotation follow its true arc instead of a straight chord.
layout(set = 1, binding = 0, std140) uniform Reprojection {
	mat4 steps[MB_MAX_STEPS];
	mat4 inv_projection;
} reproj;

// Per-frame values: raster size and the screen-space focus capsule.
layout(push_constant, std430) uniform Frame {
	vec2 raster_size;
	vec2 reserved;
	vec4 focus_endpoints; // xy = feet UV, zw = head UV
	vec4 focus_shape;     // xy = radius UV, z = distance, w = half depth
} frame;

// --- Helpers ---------------------------------------------------------------

float sample_depth(vec2 p_uv) {
#ifdef USE_MSAA_DEPTH
	return texelFetch(depth_tex, ivec2(p_uv * frame.raster_size), 0).x;
#else
	return textureLod(depth_tex, p_uv, 0.0).x;
#endif
}

vec2 project_uv(mat4 p_matrix, vec4 p_clip) {
	vec4 out_clip = p_matrix * p_clip;
	return (out_clip.xy / out_clip.w) * 0.5 + 0.5;
}

// Reversed-Z: depth = 1 at the near plane, 0 at the far plane/sky. Unproject
// the NDC point to recover the true linear view distance in metres.
float linear_distance(vec2 p_uv, float p_depth) {
	vec4 view = reproj.inv_projection * vec4(p_uv * 2.0 - 1.0, p_depth, 1.0);
	return abs(view.z / view.w);
}

// Keeps the tracked character sharp: a screen-space capsule swept from feet to
// head, limited to the character's depth band so world geometry at a different
// distance is not unblurred with it.
float focus_mask(vec2 p_uv, float p_distance) {
	if (frame.focus_shape.z <= 0.0) {
		return 0.0;
	}

	vec2 radius = max(frame.focus_shape.xy, vec2(1e-4));
	vec2 pa = (p_uv - frame.focus_endpoints.xy) / radius;
	vec2 ba = (frame.focus_endpoints.zw - frame.focus_endpoints.xy) / radius;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
	float radial = 1.0 - smoothstep(0.95, 1.2, length(pa - ba * h));

	float half_depth = max(frame.focus_shape.w, 0.05);
	float depth = 1.0 - smoothstep(half_depth, half_depth * 1.4, abs(p_distance - frame.focus_shape.z));
	return radial * depth;
}

void main() {
	vec4 base_color = textureLod(color_tex, uv_interp, 0.0);
	if (MB_SAMPLE_COUNT < 2 || MB_SHUTTER_ANGLE_DEG <= 0.0) {
		out_color = base_color;
		return;
	}

	float depth = sample_depth(uv_interp);
	float distance = linear_distance(uv_interp, depth);
	if (depth <= 0.0) {
		out_color = base_color; // Reversed depth: far plane / sky is 0.0.
		return;
	}

	// Fully focused pixels keep the current frame and skip the reprojection.
	float focus = focus_mask(uv_interp, distance);
	if (focus >= 0.999) {
		out_color = base_color;
		return;
	}

	vec4 clip = vec4(uv_interp * 2.0 - 1.0, depth, 1.0);
	vec2 previous_uv = project_uv(reproj.steps[0], clip);
	float vel_px = length((previous_uv - uv_interp) * frame.raster_size);

	// `amount` shortens the whole arc toward the current pixel so the shutter
	// and max radius act as artistic controls; the gate fades in slow motion.
	float gate = 1.0;
	if (MB_MOTION_THRESHOLD_PX > 0.0) {
		// Fade in over a small feather so the threshold does not leave a
		// hard contour where slow pixels cross it.
		float feather = max(MB_MOTION_THRESHOLD_PX * 0.25, 1.0);
		gate = smoothstep(MB_MOTION_THRESHOLD_PX, MB_MOTION_THRESHOLD_PX + feather, vel_px);
	}
	float shutter = clamp(MB_SHUTTER_ANGLE_DEG / 360.0, 0.0, 1.0);
	float amount = min(1.0, MB_MAX_RADIUS_PX / max(vel_px, 1e-6)) * shutter * gate;
	amount *= 1.0 - focus;
	if (amount * vel_px < 0.05) {
		out_color = base_color;
		return;
	}

#ifdef MB_DEBUG_BLUR
	// Debug view: tint every pixel that the blur would touch. The red
	// intensity is the sampled arc length relative to the radius cap, with a
	// floor so even short arcs are visible.
	float heat = clamp(amount * vel_px / MB_MAX_RADIUS_PX, 0.0, 1.0);
	out_color = vec4(mix(base_color.rgb, vec3(1.0, 0.0, 0.0), 0.25 + 0.75 * heat), 1.0);
	return;
#endif

	// Integrate along the arc. The last tap is the current pixel itself
	// (base_color), so taps 0..MB_SAMPLE_COUNT-2 plus the base cover the
	// exposure evenly.
	vec4 sum = base_color;
	float weight_sum = 1.0;
	for (int i = 0; i < MB_SAMPLE_COUNT - 1; i++) {
		vec2 tap_uv = clamp(mix(uv_interp, project_uv(reproj.steps[i], clip), amount),
			vec2(0.001), vec2(0.999));
#ifdef MB_DEPTH_REJECT
		// Drop taps that land on a nearer surface: an occluder there would
		// otherwise bleed a hidden object into the blur.
		float tap_distance = linear_distance(tap_uv, sample_depth(tap_uv));
		float visible = step(distance * 0.75, tap_distance);
#else
		float visible = 1.0;
#endif
		sum += textureLod(color_tex, tap_uv, 0.0) * visible;
		weight_sum += visible;
	}
	out_color = sum / weight_sum;
}
