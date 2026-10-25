class_name TreeShadowReceiver
extends MeshInstance3D

## Ground quad that shows the shared tree shadow mask under one tree.
##
## The mask itself is rendered once by [TreeShadowEffect]; this node only places
## the quad. It is oriented in the track frame published by the nearest tree
## rather than in the tree's own frame, so every tree repeats the same footprint
## and the instance's random placement yaw does not spin the shadow.

func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	material_override = TreeShadowState.shadow_material()
	var tree := get_parent()
	var trunk := tree.get_node_or_null("Trunk") as MeshInstance3D
	var leaves := tree.get_node_or_null("Leaves") as MultiMeshInstance3D
	TreeShadowState.ensure_source(trunk, leaves)
	visible = false


func _process(_delta: float) -> void:
	# Publish the sun even while the mask is missing: the effect needs it before
	# it can render and publish the texture.
	var sun := TreeShadowState.refresh_sun(self)
	if sun.y >= -TreeShadowState.MIN_SUN_HEIGHT:
		visible = false
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		visible = false
		return
	var tree := get_parent() as Node3D
	# Also settle the shared track frame before the first mask render.
	TreeShadowState.publish_frame(tree, camera)
	if TreeShadowState.texture == null:
		visible = false
		return

	var tree_scale := tree.global_transform.basis.get_scale().x
	var basis := (
		Basis.looking_at(TreeShadowState.track_forward, Vector3.UP)
		.scaled(Vector3.ONE * tree_scale * TreeShadowState.CELL_SIZE)
	)
	global_transform = Transform3D(
		basis, tree.global_position + Vector3(0.0, TreeShadowState.GROUND_Y, 0.0)
	)
	visible = true
