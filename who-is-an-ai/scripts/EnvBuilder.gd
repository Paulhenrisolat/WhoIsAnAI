@tool
extends Node3D
## EnvBuilder - EDITOR-ONLY one-shot environment generator.
##
## HOW TO USE:
## 1. Open scenes/Main.tscn in the Godot editor.
## 2. Select this node (EnvBuilder) in the scene tree.
## 3. In the Inspector, tick "Build Now". The whole environment is created as
##    real, editable child nodes under a single "Environment" node:
##      Environment/
##        WorldEnvironment, Sun, Starfield,
##        Room (your FBX), ShipHull (your FBX, placed BELOW the floor),
##        Ship/ (primitive hull walls, rails, pillars, fins, engine glow),
##        Props/ (each prop instance), CollisionWalls/, PlayArea (Marker3D)
## 4. Untick nothing else - just SAVE the scene (Ctrl+S). Everything is now
##    plain nodes you can move/scale/recolor by hand.
## 5. Optional: once built, you can delete this EnvBuilder node entirely.
##    Main.gd auto-detects the "Environment" node and skips code generation.
##
## Re-running "Build Now" deletes the previous "Environment" node first, so
## your manual edits WILL be lost if you rebuild. Build once, then edit.

# ---- Tunables (mirrors of the old Main.gd constants) ----
@export_group("Actions")
## Tick to (re)generate. It auto-resets to false.
@export var build_now: bool = false:
	set(v):
		build_now = false
		if v and Engine.is_editor_hint():
			_build()
## Tick to remove the generated Environment node.
@export var clear_now: bool = false:
	set(v):
		clear_now = false
		if v and Engine.is_editor_hint():
			_clear()

@export_group("Room")
## Fixed room scale (this builder does NOT auto-measure; adjust by hand after).
@export var room_scale: float = 14.0
@export var room_model: String = "res://assets/models/Room.fbx"
## Half-width of the room footprint AFTER scaling, used to place everything
## else. Eyeball it from the room, then nudge in the editor.
@export var room_half: float = 23.0

@export_group("Play area")
@export var wall_inset: float = 0.57
@export var prop_ring: float = 0.53

@export_group("Skybox")
@export var star_count: int = 1400
@export var sky_top: Color = Color(0.02, 0.02, 0.06)
@export var sky_horizon: Color = Color(0.05, 0.04, 0.10)

@export_group("Ship hull (FBX, placed below floor) - DISABLED by default")
## Leave empty to skip the ship hull entirely. Put back the path to use it.
@export var ship_hull_model: String = ""
@export var ship_hull_scale: float = 14.0
@export var ship_hull_y: float = -2.0

@export_group("Ship chassis (primitives)")
@export var ship_wall_height: float = 5.0
@export var ship_wall_thickness: float = 1.2
@export var ship_margin: float = 2.5
@export var hull_color: Color = Color(0.30, 0.34, 0.42)
@export var trim_color: Color = Color(0.55, 0.62, 0.75)
@export var fin_color: Color = Color(0.22, 0.25, 0.32)

@export_group("Props")
@export var prop_models: PackedStringArray = [
	"res://assets/models/props/Barrel.fbx",
	"res://assets/models/props/Crate.fbx",
	"res://assets/models/props/Engine.fbx",
	"res://assets/models/props/Medical Bed.fbx",
	"res://assets/models/props/Meeting Table.fbx",
	"res://assets/models/props/Captains Chair.fbx",
	"res://assets/models/props/TaskStation.fbx",
	"res://assets/models/props/Temperature Panel.fbx",
	"res://assets/models/props/Counting Panel.fbx",
]

const ENV_NAME := "Environment"


func _clear() -> void:
	var old := get_parent().get_node_or_null(ENV_NAME)
	if old:
		old.free()
		print("[EnvBuilder] Cleared '%s'." % ENV_NAME)


func _build() -> void:
	var root_owner := get_tree().edited_scene_root
	if root_owner == null:
		push_warning("[EnvBuilder] Open Main.tscn in the editor first.")
		return
	_clear()

	var env := Node3D.new()
	env.name = ENV_NAME
	get_parent().add_child(env)
	env.owner = root_owner

	_add_environment(env, root_owner)
	_add_sun(env, root_owner)
	if star_count > 0:
		_add_starfield(env, root_owner)
	_add_room(env, root_owner)
	_add_ship_hull(env, root_owner)
	_add_ship(env, root_owner)
	_add_props(env, root_owner)
	_add_collision_walls(env, root_owner)
	_add_play_marker(env, root_owner)

	print("[EnvBuilder] Built '%s'. Save the scene (Ctrl+S). You can now edit everything by hand or delete EnvBuilder." % ENV_NAME)


# Recursively assign owner so nodes are SAVED into the scene and visible/editable.
func _own(node: Node, owner_root: Node) -> void:
	node.owner = owner_root
	for c in node.get_children():
		_own(c, owner_root)


func _add_environment(parent: Node3D, owner_root: Node) -> void:
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var m := ProceduralSkyMaterial.new()
	m.sky_top_color = sky_top
	m.sky_horizon_color = sky_horizon
	m.ground_bottom_color = sky_top
	m.ground_horizon_color = sky_horizon
	sky.sky_material = m
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.5
	e.ambient_light_color = Color(0.55, 0.55, 0.65)
	we.environment = e
	parent.add_child(we)
	we.owner = owner_root


func _add_sun(parent: Node3D, owner_root: Node) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.shadow_enabled = true
	parent.add_child(sun)
	sun.owner = owner_root


func _add_starfield(parent: Node3D, owner_root: Node) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var star_mat := StandardMaterial3D.new()
	star_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	star_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	star_mat.vertex_color_use_as_albedo = true
	quad.material = star_mat
	mm.mesh = quad
	mm.instance_count = star_count
	var radius := 220.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260101
	for i in star_count:
		var u := rng.randf() * 2.0 - 1.0
		var theta := rng.randf() * TAU
		var r := sqrt(1.0 - u * u)
		var dir := Vector3(r * cos(theta), u, r * sin(theta)).normalized()
		var size := rng.randf_range(0.6, 2.4)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(size, size, size)), dir * radius))
		var b := rng.randf_range(0.5, 1.0)
		mm.set_instance_color(i, Color(b, b, rng.randf_range(b * 0.8, 1.0)))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Starfield"
	mmi.multimesh = mm
	parent.add_child(mmi)
	mmi.owner = owner_root


func _add_room(parent: Node3D, owner_root: Node) -> void:
	if not ResourceLoader.exists(room_model):
		push_warning("[EnvBuilder] Room model not found: %s" % room_model)
		return
	var scene := load(room_model) as PackedScene
	var room := scene.instantiate()
	room.name = "Room"
	if room is Node3D:
		(room as Node3D).scale = Vector3.ONE * room_scale
	parent.add_child(room)
	# Only set owner on the instance root: keeps it as a single editable
	# instance (its internal nodes stay part of the imported scene).
	room.owner = owner_root


func _add_ship_hull(parent: Node3D, owner_root: Node) -> void:
	if ship_hull_model.is_empty():
		return  # Disabled on purpose.
	if not ResourceLoader.exists(ship_hull_model):
		push_warning("[EnvBuilder] ship_hull not found (skipped): %s" % ship_hull_model)
		return
	var scene := load(ship_hull_model) as PackedScene
	var hull := scene.instantiate()
	hull.name = "ShipHull"
	if hull is Node3D:
		var n := hull as Node3D
		n.scale = Vector3.ONE * ship_hull_scale
		n.position.y = ship_hull_y  # placed below the floor
	parent.add_child(hull)
	hull.owner = owner_root


func _add_ship(parent: Node3D, owner_root: Node) -> void:
	var ship := Node3D.new()
	ship.name = "Ship"
	parent.add_child(ship)
	ship.owner = owner_root
	var half: float = room_half + ship_margin
	var h := ship_wall_height
	var t := ship_wall_thickness
	var span := half * 2.0
	var hull_mat := _solid(hull_color)
	var trim_mat := _solid(trim_color)
	var fin_mat := _solid(fin_color)

	var walls := [
		[Vector3(0, h * 0.5, -half), Vector3(span, h, t)],
		[Vector3(0, h * 0.5, half), Vector3(span, h, t)],
		[Vector3(-half, h * 0.5, 0), Vector3(t, h, span)],
		[Vector3(half, h * 0.5, 0), Vector3(t, h, span)],
	]
	for w in walls:
		_box_into(ship, "HullWall", w[0], w[1], hull_mat, owner_root)
	var rails := [
		[Vector3(0, h, -half), Vector3(span, 0.3, t * 1.3)],
		[Vector3(0, h, half), Vector3(span, 0.3, t * 1.3)],
		[Vector3(-half, h, 0), Vector3(t * 1.3, 0.3, span)],
		[Vector3(half, h, 0), Vector3(t * 1.3, 0.3, span)],
	]
	for r in rails:
		_box_into(ship, "Rail", r[0], r[1], trim_mat, owner_root)
	for sx in [-half, half]:
		for sz in [-half, half]:
			_box_into(ship, "Pillar", Vector3(sx, h * 0.6, sz), Vector3(t * 1.8, h * 1.2, t * 1.8), trim_mat, owner_root)
	var fin_len: float = half * 0.7
	var fins := [
		[Vector3(0, 0.6, -half - fin_len * 0.5), Vector3(span * 0.4, 1.2, fin_len)],
		[Vector3(0, 0.6, half + fin_len * 0.5), Vector3(span * 0.4, 1.2, fin_len)],
		[Vector3(-half - fin_len * 0.5, 0.6, 0), Vector3(fin_len, 1.2, span * 0.4)],
		[Vector3(half + fin_len * 0.5, 0.6, 0), Vector3(fin_len, 1.2, span * 0.4)],
	]
	for f in fins:
		_box_into(ship, "Fin", f[0], f[1], fin_mat, owner_root)
	var glow := _solid(Color(0.4, 0.7, 1.0))
	glow.emission_enabled = true
	glow.emission = Color(0.3, 0.6, 1.0)
	glow.emission_energy_multiplier = 2.0
	_box_into(ship, "EngineGlow", Vector3(0, 0.8, half + fin_len), Vector3(span * 0.25, 1.0, 1.0), glow, owner_root)


func _add_props(parent: Node3D, owner_root: Node) -> void:
	var holder := Node3D.new()
	holder.name = "Props"
	parent.add_child(holder)
	holder.owner = owner_root
	var ring: float = room_half * prop_ring
	var count := prop_models.size()
	for i in count:
		var path := prop_models[i]
		if not ResourceLoader.exists(path):
			continue
		var prop := (load(path) as PackedScene).instantiate()
		if prop is Node3D:
			var p := prop as Node3D
			var ang := TAU * float(i) / float(count)
			p.position = Vector3(cos(ang) * ring, 0.0, sin(ang) * ring)
			p.rotation_degrees.y = rad_to_deg(-ang) + 90.0
		holder.add_child(prop)
		prop.owner = owner_root


func _add_collision_walls(parent: Node3D, owner_root: Node) -> void:
	var holder := Node3D.new()
	holder.name = "CollisionWalls"
	parent.add_child(holder)
	holder.owner = owner_root
	var half: float = maxf(4.0, room_half * wall_inset)
	var specs := [
		[Vector3(0, 2, -half), Vector3(half, 4, 0.5)],
		[Vector3(0, 2, half), Vector3(half, 4, 0.5)],
		[Vector3(-half, 2, 0), Vector3(0.5, 4, half)],
		[Vector3(half, 2, 0), Vector3(0.5, 4, half)],
	]
	for s in specs:
		var body := StaticBody3D.new()
		body.name = "Wall"
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = (s[1] as Vector3) * 2.0
		col.shape = shape
		body.add_child(col)
		body.position = s[0]
		holder.add_child(body)
		body.owner = owner_root
		col.owner = owner_root


func _add_play_marker(parent: Node3D, owner_root: Node) -> void:
	# Main.gd reads this marker to know the walkable half-width without
	# recomputing anything. Its X scale encodes play_half.
	var marker := Marker3D.new()
	marker.name = "PlayArea"
	marker.set_meta("play_half", maxf(4.0, room_half * wall_inset))
	parent.add_child(marker)
	marker.owner = owner_root


# ---- helpers ----
func _solid(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.6
	return m


func _box_into(parent: Node3D, node_name: String, pos: Vector3, size: Vector3, mat: StandardMaterial3D, owner_root: Node) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	mi.owner = owner_root
