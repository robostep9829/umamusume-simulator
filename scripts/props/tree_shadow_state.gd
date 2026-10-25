class_name TreeShadowState
extends RefCounted

## Shared state of the single tree shadow mask rendered by [TreeShadowEffect].
##
## The mask is rendered at most once per frame, and only when the sun moves
## relative to the track, then sampled by the ground quad of every rural tree. A
## tree instance therefore repeats the same footprint instead of owning a render
## pass: the scenery pool holds hundreds of props, and a viewport per tree is far
## too expensive on mobile.
##
## The effect flattens the canonical tree along the sun in the current track
## frame, and every receiver orients its quad in that same frame. The frame
## cancels between the two, so the footprint still points along the world sun;
## what the frame decides is the footprint *shape* - the sun's angle relative to
## the track forward axis, which is what the mask is rendered for.

## Resolution of the shared mask.
const MASK_SIZE := 256
## Side of the ground square the mask covers, in tree-local metres.
const CELL_SIZE := 32.0
## Shallowest sun the shadow is drawn for; lower suns stretch the footprint past
## the covered square.
const MIN_SUN_HEIGHT := 0.25
## Lift of the quad above the track surface.
const GROUND_Y := 0.05
const SHADOW_COLOR := Color(0.02, 0.04, 0.02, 0.5)
const SOFTNESS := 1.0

const BLIT_SHADER: Shader = preload(
	"res://worlds/scrolling_track/biomes/rural/materials/shaders/tree_shadow_blit.gdshader"
)

## True once [method ensure_source] has extracted the tree's triangles.
static var source_ready := false
static var vertex_count := 0
static var vertex_bytes := PackedByteArray()

## The mask, published by the compositor effect after its first render.
static var texture: Texture2DRD = null

## World-space direction the sunlight travels, published by the receivers.
static var sun_world := Vector3.ZERO

## Forward axis of the nearest tree's hosting track segment. The mask is rendered
## against this direction, and every receiver's quad is oriented by it, so all
## shadows share one track-relative footprint.
static var track_forward := Vector3.FORWARD

static var _sun_light: DirectionalLight3D
static var _material: ShaderMaterial
static var _frame_stamp := -1
static var _nearest_distance := INF


## One material serves every tree: the texture and the tint are the same for all
## of them.
static func shadow_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = BLIT_SHADER
		_material.render_priority = 2
		_material.set_shader_parameter("shadow_color", SHADOW_COLOR)
		_material.set_shader_parameter("softness", SOFTNESS)
		_material.set_shader_parameter("texel", Vector2.ONE / float(MASK_SIZE))
		if texture != null:
			_material.set_shader_parameter("shadow_tex", texture)
	return _material


## Called on the main thread by the effect once its mask texture exists.
static func set_rd_texture(rd_texture: RID) -> void:
	texture = Texture2DRD.new()
	texture.texture_rd_rid = rd_texture
	shadow_material().set_shader_parameter("shadow_tex", texture)


## Called from the effect's predelete hook so receivers stop sampling a texture
## whose rendering device resource is about to disappear.
static func clear_texture() -> void:
	texture = null
	if _material != null and is_instance_valid(_material):
		_material.set_shader_parameter("shadow_tex", null)
	_material = null
	_sun_light = null


## Extracts the canonical tree - trunk plus every leaf instance - into one
## triangle soup in tree-local space. Runs once, from the first receiver.
static func ensure_source(trunk: MeshInstance3D, leaves: MultiMeshInstance3D) -> void:
	if source_ready:
		return
	source_ready = true

	var vertices := PackedFloat32Array()
	if trunk != null and trunk.mesh != null:
		_append_mesh(vertices, trunk.mesh, trunk.transform)
	if leaves != null and leaves.multimesh != null and leaves.multimesh.mesh != null:
		var leaf_triangles := _triangles(leaves.multimesh.mesh)
		for instance in leaves.multimesh.instance_count:
			var placement := leaves.transform * leaves.multimesh.get_instance_transform(instance)
			for vertex in leaf_triangles:
				var point := placement * vertex
				vertices.append(point.x)
				vertices.append(point.y)
				vertices.append(point.z)
	vertex_count = vertices.size() / 3
	vertex_bytes = vertices.to_byte_array()


## The level's directional light, cached across all trees, as a travel direction.
static func refresh_sun(from: Node) -> Vector3:
	if _sun_light == null or not is_instance_valid(_sun_light) or not _sun_light.is_inside_tree():
		_sun_light = null
		var tree := from.get_tree()
		if tree != null:
			for node in tree.root.find_children("*", "DirectionalLight3D", true, false):
				var light := node as DirectionalLight3D
				if light != null and light.visible and light.light_energy > 0.0:
					_sun_light = light
					break
	if _sun_light == null:
		if sun_world != Vector3.ZERO:
			sun_world = Vector3.ZERO
	else:
		# The render thread reads this; only touch it when it actually changes.
		var direction := -_sun_light.global_transform.basis.z.normalized()
		if direction != sun_world:
			sun_world = direction
	return sun_world


## Lets the tree closest to the camera decide the shared track frame for this
## frame. Segment headings differ along a curve, and one mask serves every tree,
## so the frame has to come from the track around the runner rather than from an
## arbitrary instance.
static func publish_frame(tree: Node3D, camera: Camera3D) -> void:
	var stamp := Engine.get_process_frames()
	if stamp != _frame_stamp:
		_frame_stamp = stamp
		_nearest_distance = INF
	var distance := camera.global_position.distance_squared_to(tree.global_position)
	if distance >= _nearest_distance:
		return
	_nearest_distance = distance

	var segment := _hosting_segment(tree)
	var forward := -segment.global_transform.basis.z if segment != null else Vector3.FORWARD
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return
	forward = forward.normalized()
	if forward != track_forward:
		track_forward = forward


static func _hosting_segment(tree: Node3D) -> StaticBody3D:
	var node := tree.get_parent()
	while node != null:
		if node is StaticBody3D:
			return node as StaticBody3D
		node = node.get_parent()
	return null


static func _append_mesh(out: PackedFloat32Array, mesh: Mesh, placement: Transform3D) -> void:
	for vertex in _triangles(mesh):
		var point := placement * vertex
		out.append(point.x)
		out.append(point.y)
		out.append(point.z)


static func _triangles(mesh: Mesh) -> PackedVector3Array:
	var triangles := PackedVector3Array()
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices = arrays[Mesh.ARRAY_INDEX]
		if indices is PackedInt32Array and not (indices as PackedInt32Array).is_empty():
			for index in indices as PackedInt32Array:
				triangles.append(vertices[index])
		else:
			triangles.append_array(vertices)
	return triangles
