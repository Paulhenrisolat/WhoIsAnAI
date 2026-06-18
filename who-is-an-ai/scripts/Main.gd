extends Node3D
## Main scene: builds the 3D world and UI, handles detective control,
## the FBX character visuals and the fake matchmaking screen.

const SPEED := 6.0
# Detective physics collider (capsule). Tune if it clips or floats.
const DET_COLLIDER_RADIUS := 0.6
const DET_COLLIDER_HEIGHT := 1.8
# Height the detective body is kept at (top-down, flat floor, no gravity).
const DET_SPAWN_Y := 0.1

# --- Character model (FBX) ---
const CHARACTER_MODEL := "res://assets/models/spaceman/Spaceman.fbx"
const FALLBACK_MODEL := "res://assets/Cube_Man_Character.fbx"
# Mixamo animations live in separate FBX files. Godot imports each one as a
# scene containing an AnimationPlayer; we pull their clips into every spawned
# character. If they can't be loaded, characters fall back to a floating bob.
const ANIM_FILES := {
	"idle": "res://assets/models/spaceman/animations/Idle.fbx",
	"walk": "res://assets/models/spaceman/animations/Walk.fbx",
	"run": "res://assets/models/spaceman/animations/Run.fbx",
}
# --- Environment ---
const ROOM_MODEL := "res://assets/models/Room.fbx"
# 0.0 = auto-measure the room and scale it to fill the play area.
# Set to a fixed number (e.g. 10.0) to override the automatic scaling.
const ROOM_SCALE := 0.0
# Target interior width the room should cover (world units). Bigger = roomier.
const ROOM_TARGET_SIZE := 46.0
# Fraction of the room's outer half-width that is actually walkable (the rest
# is the wall thickness). Lower this if the player still clips through walls.
# This ONLY affects the invisible collision walls, not the props.
const WALL_INSET := 0.57
# Fraction of the room's raw half-width where decorative props sit. Independent
# from WALL_INSET so tuning the walls never moves the props.
const PROP_RING := 0.53
# Label height above each character's feet.
const LABEL_HEIGHT := 3.1

# --- Space skybox ---
const SKYBOX_ENABLED := true
const STAR_COUNT := 1400           # number of stars on the sky sphere
const SKY_TOP := Color(0.02, 0.02, 0.06)
const SKY_HORIZON := Color(0.05, 0.04, 0.10)

# --- Spaceship chassis (open-roof shell around the room) ---
const SHIP_ENABLED := true
const SHIP_WALL_HEIGHT := 5.0     # height of the hull walls
const SHIP_WALL_THICKNESS := 1.2  # how thick/chunky the hull reads
const SHIP_MARGIN := 2.5          # gap between the room edge and the hull
const SHIP_HULL_COLOR := Color(0.30, 0.34, 0.42)
const SHIP_TRIM_COLOR := Color(0.55, 0.62, 0.75)
const SHIP_FIN_COLOR := Color(0.22, 0.25, 0.32)
const PROP_FILES := [
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
# Adjust these if the model imports with a different size/orientation.
const MODEL_SCALE := 1.0
const MODEL_Y_OFFSET := 0.0
const MODEL_ROT_Y_DEG := 180.0
# Procedural idle floating (applied to static, non-rigged models).
const BOB_HEIGHT := 0.12
const BOB_SPEED := 1.6
const DETECTIVE_TINT := Color(0.45, 0.65, 1.0)
const RESOLVED_AI_TINT := Color(1.0, 0.35, 0.35)
const RESOLVED_HUMAN_TINT := Color(0.4, 1.0, 0.5)

var _model_scene: PackedScene
var _char_nodes := {}        # char_id -> Node3D (root, positioned in the room)
var _char_anim := {}         # char_id -> AnimationPlayer
var _char_visual := {}       # char_id -> visual node (for procedural bob)
var _ejecting := {}          # char_id -> true while its eject animation plays
var _starfield: Node3D       # the star sphere, slowly rotated for ambience
# Star sphere rotation speed (radians/second). Higher = faster space drift.
const STAR_SPIN_SPEED := 0.012
var _bob_phase := {}         # char_id -> float (desync the floating)
var _det_move_cooldown := 0.0
var _model_has_rig := false
var _intro_active := false
var _loaded_anims := {}      # "idle"/"walk"/"run" -> Animation resource
var _env_root: Node3D
var _play_half := 13.0       # half-width of the walkable area (collision walls)
var _room_half := 13.0       # raw half-width of the room (props use this)
var _cam: Camera3D
var _pos_timer := 0.0
var _my_pos := Vector3.ZERO
var _det_spawn_y := 0.1
var _chat_target := -1
var _nearest := -1

# --- Fake matchmaking screen state (driven by the REAL participant total) ---
var _mm_elapsed := 0.0
var _mm_found := 1
var _mm_total := 6
var _mm_times: Array = []    # precomputed "player found" timestamps

# --- UI ---
var _lobby_root: CenterContainer
var _mm_root: CenterContainer
var _mm_label: Label
var ui_status: Label
var ui_score: Label
var ui_hint: Label
var ui_nickname: LineEdit
var ui_btn_start: Button
var _connected := false
var ui_chat: PanelContainer
var ui_chat_header: Label
var ui_chat_log: RichTextLabel
var ui_chat_input: LineEdit
var ui_typing: Label
var ui_vote_box: HBoxContainer
var _typing_sent := false

# --- Intro sequence ---
var _intro_root: ColorRect
var _intro_label: Label

var _step_timer := 0.0
const STEP_INTERVAL := 0.30   # délai entre deux pas (plus petit = pas plus rapides)

func _ready() -> void:
	_setup_input()
	_build_world()
	_build_ui()
	_load_character_model()

	Net.status_changed.connect(func(m: String): ui_status.text = m)
	Net.roster_updated.connect(_refresh_roster)
	Net.game_synced.connect(_on_game_synced)
	Net.my_id_set.connect(_on_my_id)
	Net.matchmaking_started.connect(_on_matchmaking)
	Net.detective_moved.connect(_on_det_moved)
	Net.chat_opened.connect(_on_chat_opened)
	Net.chat_closed.connect(_on_chat_closed)
	Net.chat_message.connect(_on_chat_msg)
	Net.chat_typing.connect(_on_chat_typing)
	Net.verdict.connect(_on_verdict)
	Net.game_over.connect(_on_game_over)
	Net.connected_ok.connect(_on_connected)
	Net.connection_lost.connect(func(): _lobby_root.visible = true)

	# Dedicated server: godot --headless  (or: godot -- --server)
	if DisplayServer.get_name() == "headless" or OS.get_cmdline_user_args().has("--server"):
		Net.play("Server", Net.DEFAULT_ADDRESS)


func _load_character_model() -> void:
	if ResourceLoader.exists(CHARACTER_MODEL):
		_model_scene = load(CHARACTER_MODEL) as PackedScene
	if _model_scene == null and ResourceLoader.exists(FALLBACK_MODEL):
		push_warning("Main model not found, using fallback %s." % FALLBACK_MODEL)
		_model_scene = load(FALLBACK_MODEL) as PackedScene
	if _model_scene == null:
		push_warning("No character model could be loaded - falling back to capsules. Open the project once in the Godot editor so the FBX gets imported.")
		ui_status.text = "WARNING: character model not imported yet - using capsules (see console)."
		return
	# The Spaceman mesh itself usually ships without clips; the clips live in the
	# separate Mixamo FBX files. Pull one Animation resource out of each.
	for key in ANIM_FILES:
		var path: String = ANIM_FILES[key]
		if not ResourceLoader.exists(path):
			continue
		var scene := load(path) as PackedScene
		if scene == null:
			continue
		var probe := scene.instantiate()
		var ap := _find_anim_player(probe)
		if ap != null:
			for anim_name in ap.get_animation_list():
				var a := ap.get_animation(anim_name)
				if a != null and a.length > 0.1:
					_loaded_anims[key] = a.duplicate()
					break
		probe.free()
	# Rigged if the mesh has a skeleton (so we can drive the loaded clips).
	var probe2 := _model_scene.instantiate()
	var skel: Skeleton3D = null
	for f in probe2.find_children("*", "Skeleton3D", true, false):
		skel = f as Skeleton3D
		break
	_model_has_rig = skel != null and not _loaded_anims.is_empty()
	probe2.free()
	if not _model_has_rig:
		push_warning("Spaceman animations not found/applied - using floating bob. In the Godot editor, make sure the Idle/Walk/Run FBX import as animations.")


# =====================================================================
# INPUT (physical keys => WASD works on AZERTY keyboards as ZQSD)
# =====================================================================

func _setup_input() -> void:
	var phys := {
		"move_up": KEY_W, "move_down": KEY_S,
		"move_left": KEY_A, "move_right": KEY_D,
		"interact": KEY_E,
	}
	for action in phys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = phys[action]
		InputMap.action_add_event(action, ev)
	var arrows := [["move_up", KEY_UP], ["move_down", KEY_DOWN], ["move_left", KEY_LEFT], ["move_right", KEY_RIGHT]]
	for pair in arrows:
		var ev2 := InputEventKey.new()
		ev2.keycode = pair[1]
		InputMap.action_add_event(pair[0], ev2)


# =====================================================================
# 3D WORLD
# =====================================================================

func _build_world() -> void:
	# If a prebuilt "Environment" node exists in the scene (made with the
	# EnvBuilder @tool script), use it as-is and skip all code generation.
	var prebuilt := get_node_or_null("Environment")
	if prebuilt != null:
		_use_prebuilt_environment(prebuilt)
		return
	_build_world_procedural()


func _use_prebuilt_environment(env_node: Node) -> void:
	# Read the walkable half-width from the PlayArea marker if present.
	var marker := env_node.get_node_or_null("PlayArea")
	if marker != null and marker.has_meta("play_half"):
		_play_half = float(marker.get_meta("play_half"))
		_room_half = _play_half  # props are already placed; this is just a guard
	# Grab the starfield so it can spin (works for the EnvBuilder version too).
	_starfield = env_node.get_node_or_null("Starfield")
	# Remove any leftover EnvBuilder node so it never runs at game time.
	var builder := get_node_or_null("EnvBuilder")
	if builder != null:
		builder.queue_free()
	_cam = Camera3D.new()
	_cam.position = Vector3(0.0, 19.0, 15.0)
	add_child(_cam)
	_cam.look_at(Vector3.ZERO)


func _build_world_procedural() -> void:
	var builder := get_node_or_null("EnvBuilder")
	if builder != null:
		builder.queue_free()

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	if SKYBOX_ENABLED:
		e.background_mode = Environment.BG_SKY
		var sky := Sky.new()
		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = SKY_TOP
		sky_mat.sky_horizon_color = SKY_HORIZON
		sky_mat.ground_bottom_color = SKY_TOP
		sky_mat.ground_horizon_color = SKY_HORIZON
		sky_mat.sun_angle_max = 1.0
		sky.sky_material = sky_mat
		e.sky = sky
		e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		e.ambient_light_energy = 0.5
	else:
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color(0.07, 0.08, 0.11)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_energy = 0.7
	e.ambient_light_color = Color(0.55, 0.55, 0.65)
	env.environment = e
	add_child(env)

	if SKYBOX_ENABLED:
		_build_starfield()

	_env_root = Node3D.new()
	add_child(_env_root)

	var room_loaded := false
	if ResourceLoader.exists(ROOM_MODEL):
		var scene := load(ROOM_MODEL) as PackedScene
		if scene != null:
			var room := scene.instantiate()
			if room is Node3D:
				_env_root.add_child(room)
				_autoscale_room(room as Node3D)
				room_loaded = true
	if not room_loaded:
		_build_primitive_floor()

	_scatter_props()

	if SHIP_ENABLED:
		_build_ship()

	_cam = Camera3D.new()
	_cam.position = Vector3(0.0, 19.0, 15.0)
	add_child(_cam)
	_cam.look_at(Vector3.ZERO)


func _autoscale_room(room: Node3D) -> void:
	# The FBX may import at any unit scale. Measure its combined mesh bounds and
	# scale so its footprint roughly fills ROOM_TARGET_SIZE.
	# Override by setting ROOM_SCALE to anything other than 0.
	var factor := ROOM_SCALE
	var aabb := _node_aabb(room)
	if ROOM_SCALE == 0.0:
		var footprint: float = maxf(aabb.size.x, aabb.size.z)
		if footprint <= 0.001:
			return
		factor = ROOM_TARGET_SIZE / footprint
		push_warning("Room auto-scaled by factor %.3f (measured footprint %.2f)." % [factor, footprint])
	room.scale = Vector3.ONE * factor
	# Re-center on origin and drop to floor level (y=0) after scaling.
	var scaled_center := aabb.get_center() * factor
	room.position = Vector3(-scaled_center.x, -aabb.position.y * factor, -scaled_center.z)
	# Outer half-width AFTER scaling (raw room size, walls included). Props use
	# this so they DON'T move when WALL_INSET changes.
	_room_half = maxf(aabb.size.x, aabb.size.z) * factor * 0.5
	# Walkable half-width: only WALL_INSET affects this (the collision walls).
	_play_half = maxf(4.0, _room_half * WALL_INSET)
	_build_collision_walls(_play_half)


func _build_collision_walls(half: float) -> void:
	# Four static walls + a floor, invisible, forming a box of side 2*half.
	var specs := [
		[Vector3(0, 2, -half), Vector3(half, 4, 0.5)],
		[Vector3(0, 2, half), Vector3(half, 4, 0.5)],
		[Vector3(-half, 2, 0), Vector3(0.5, 4, half)],
		[Vector3(half, 2, 0), Vector3(0.5, 4, half)],
	]
	for s in specs:
		var body := StaticBody3D.new()
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = (s[1] as Vector3) * 2.0
		col.shape = shape
		body.add_child(col)
		body.position = s[0]
		_env_root.add_child(body)


func _node_aabb(node: Node3D) -> AABB:
	# Combined AABB of every MeshInstance3D under `node`, expressed in `node`
	# local space. Uses relative transforms so it works even before global
	# transforms have propagated through the tree.
	var result := AABB()
	var first := true
	for found in node.find_children("*", "MeshInstance3D", true, false):
		var mi := found as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		# Build the transform from mi up to node by walking parents.
		var xform := Transform3D.IDENTITY
		var cur: Node = mi
		while cur != null and cur != node:
			if cur is Node3D:
				xform = (cur as Node3D).transform * xform
			cur = cur.get_parent()
		var box := xform * mi.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result


func _build_starfield() -> void:
	# A dome of small unshaded billboard quads = stars. Cheap and works on the
	# gl_compatibility (web) renderer without a custom shader.
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
	mm.instance_count = STAR_COUNT

	var radius := 220.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260101
	for i in STAR_COUNT:
		# Uniform-ish points on the upper sphere (dome).
		var u := rng.randf() * 2.0 - 1.0
		var theta := rng.randf() * TAU
		var r := sqrt(1.0 - u * u)
		var dir := Vector3(r * cos(theta), u, r * sin(theta)).normalized()
		var pos := dir * radius
		var size := rng.randf_range(0.6, 2.4)
		var basis := Basis().scaled(Vector3(size, size, size))
		mm.set_instance_transform(i, Transform3D(basis, pos))
		var b := rng.randf_range(0.5, 1.0)
		mm.set_instance_color(i, Color(b, b, rng.randf_range(b * 0.8, 1.0)))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Starfield"
	mmi.multimesh = mm
	add_child(mmi)
	_starfield = mmi


func _build_ship() -> void:
	# Open-roof hull: chunky walls + corner pillars + outer fins around the
	# room, leaving the top open so the camera still sees the players.
	var ship := Node3D.new()
	add_child(ship)
	var half: float = _room_half + SHIP_MARGIN
	var h := SHIP_WALL_HEIGHT
	var t := SHIP_WALL_THICKNESS
	var span := half * 2.0

	var hull_mat := _solid(SHIP_HULL_COLOR)
	var trim_mat := _solid(SHIP_TRIM_COLOR)
	var fin_mat := _solid(SHIP_FIN_COLOR)

	# Four hull walls.
	var walls := [
		[Vector3(0, h * 0.5, -half), Vector3(span, h, t)],
		[Vector3(0, h * 0.5, half), Vector3(span, h, t)],
		[Vector3(-half, h * 0.5, 0), Vector3(t, h, span)],
		[Vector3(half, h * 0.5, 0), Vector3(t, h, span)],
	]
	for w in walls:
		ship.add_child(_box(w[0], w[1], hull_mat))
	# Bright top trim rail along each wall.
	var rails := [
		[Vector3(0, h, -half), Vector3(span, 0.3, t * 1.3)],
		[Vector3(0, h, half), Vector3(span, 0.3, t * 1.3)],
		[Vector3(-half, h, 0), Vector3(t * 1.3, 0.3, span)],
		[Vector3(half, h, 0), Vector3(t * 1.3, 0.3, span)],
	]
	for r in rails:
		ship.add_child(_box(r[0], r[1], trim_mat))
	# Corner pillars (taller, chunky).
	for sx in [-half, half]:
		for sz in [-half, half]:
			ship.add_child(_box(Vector3(sx, h * 0.6, sz), Vector3(t * 1.8, h * 1.2, t * 1.8), trim_mat))
	# Outer fins for a ship silhouette from above.
	var fin_len: float = half * 0.7
	var fins := [
		[Vector3(0, 0.6, -half - fin_len * 0.5), Vector3(span * 0.4, 1.2, fin_len)],
		[Vector3(0, 0.6, half + fin_len * 0.5), Vector3(span * 0.4, 1.2, fin_len)],
		[Vector3(-half - fin_len * 0.5, 0.6, 0), Vector3(fin_len, 1.2, span * 0.4)],
		[Vector3(half + fin_len * 0.5, 0.6, 0), Vector3(fin_len, 1.2, span * 0.4)],
	]
	for f in fins:
		ship.add_child(_box(f[0], f[1], fin_mat))
	# Faint engine glow block at the back.
	var glow := _solid(Color(0.4, 0.7, 1.0))
	glow.emission_enabled = true
	glow.emission = Color(0.3, 0.6, 1.0)
	glow.emission_energy_multiplier = 2.0
	ship.add_child(_box(Vector3(0, 0.8, half + fin_len), Vector3(span * 0.25, 1.0, 1.0), glow))


func _box(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	return mi


func _build_primitive_floor() -> void:
	_room_half = 15.0
	_play_half = 13.0
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30.0, 30.0)
	floor_mesh.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.24, 0.26, 0.31)
	floor_mesh.material_override = fmat
	_env_root.add_child(floor_mesh)

	var walls := [
		[Vector3(0, 1.5, -15), Vector3(30, 3, 1)],
		[Vector3(0, 1.5, 15), Vector3(30, 3, 1)],
		[Vector3(-15, 1.5, 0), Vector3(1, 3, 30)],
		[Vector3(15, 1.5, 0), Vector3(1, 3, 30)],
	]
	for w in walls:
		var wall := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = w[1]
		wall.mesh = bm
		wall.position = w[0]
		var wmat := StandardMaterial3D.new()
		wmat.albedo_color = Color(0.14, 0.15, 0.19)
		wall.material_override = wmat
		_env_root.add_child(wall)


func _scatter_props() -> void:
	# Decorative ambience props in a ring inside the room. Based on the raw room
	# size and PROP_RING, so changing WALL_INSET never moves them.
	var ring: float = _room_half * PROP_RING
	var count := PROP_FILES.size()
	for i in count:
		var path: String = PROP_FILES[i]
		if not ResourceLoader.exists(path):
			continue
		var scene := load(path) as PackedScene
		if scene == null:
			continue
		var prop := scene.instantiate()
		if prop is Node3D:
			var p := prop as Node3D
			var ang := TAU * float(i) / float(count)
			p.position = Vector3(cos(ang) * ring, 0.0, sin(ang) * ring)
			p.rotation_degrees.y = rad_to_deg(-ang) + 90.0
			_env_root.add_child(p)


# =====================================================================
# CHARACTER VISUALS (FBX model with color variants + animations)
# =====================================================================

func _refresh_roster() -> void:
	for cid in _char_nodes.keys():
		# Keep nodes that are mid-eject; their animation owns them now.
		if _ejecting.has(cid):
			continue
		_char_nodes[cid].queue_free()
		_char_nodes.erase(cid)
	_char_anim.clear()
	_char_visual.clear()
	_bob_phase.clear()

	for cid in Net.characters:
		# Skip a character that is currently being thrown out of the ship.
		if _ejecting.has(cid):
			continue
		var c: Dictionary = Net.characters[cid]
		# The locally-controlled detective is a real physics body so it collides
		# with the room's StaticBody walls. Everyone else is a plain Node3D.
		var root: Node3D
		var is_local_detective: bool = cid == Net.detective_id and Net.my_char_id == Net.detective_id
		if is_local_detective:
			var cb := CharacterBody3D.new()
			var col := CollisionShape3D.new()
			var cap := CapsuleShape3D.new()
			cap.radius = DET_COLLIDER_RADIUS
			cap.height = DET_COLLIDER_HEIGHT
			col.shape = cap
			# Capsule is centered on the body origin; the visual model sits at
			# the body's feet, so offset the collider up by half its height.
			col.position.y = DET_COLLIDER_HEIGHT * 0.5
			cb.add_child(col)
			root = cb
		else:
			root = Node3D.new()

		var pos: Vector3 = c["pos"] as Vector3
		if is_local_detective:
			# Spawn slightly above the floor so the capsule never starts sunk
			# inside it (which would freeze move_and_slide).
			pos.y = DET_SPAWN_Y
			_det_spawn_y = DET_SPAWN_Y
		root.position = pos
		# Subjects face random (but stable) directions so they don't all look
		# the same way. The detective is left at default; it rotates with movement.
		if cid != Net.detective_id:
			root.rotation_degrees.y = fposmod(float(cid) * 137.0, 360.0)
		root.add_child(_make_character_visual(cid, c))

		var lbl := Label3D.new()
		lbl.text = str(c["label"])
		if c["resolved"] and cid != Net.detective_id:
			lbl.text += "\n[%s]" % ("AI" if c["was_ai"] else "HUMAN")
		lbl.position.y = LABEL_HEIGHT
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.font_size = 48
		lbl.pixel_size = 0.01
		lbl.no_depth_test = true
		root.add_child(lbl)

		add_child(root)
		_char_nodes[cid] = root

	if Net.my_char_id == Net.detective_id and Net.characters.has(Net.detective_id):
		_my_pos = Net.characters[Net.detective_id]["pos"]
	ui_score.text = "Score: %d" % Net.score


func _make_character_visual(cid: int, c: Dictionary) -> Node3D:
	var tint := _tint_for(cid, c)
	if _model_scene != null:
		var inst := _model_scene.instantiate()
		if inst is Node3D:
			var model := inst as Node3D
			model.scale = Vector3.ONE * MODEL_SCALE
			model.position.y = MODEL_Y_OFFSET
			model.rotation_degrees.y = MODEL_ROT_Y_DEG
			_tint_model(model, tint)
			var ap := _find_anim_player(model)
			if ap != null and _model_has_rig:
				_install_anims(ap)
				_char_anim[cid] = ap
				_play_idle(ap)
			else:
				# No usable rig/clips: code-driven floating bob, desynced.
				_char_visual[cid] = model
				_bob_phase[cid] = randf() * TAU
			return model
	# Fallback: capsule (model missing or not imported yet).
	var holder := Node3D.new()
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.height = 1.8
	cap.radius = 0.4
	body.mesh = cap
	body.position.y = 0.9
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	body.material_override = m
	holder.add_child(body)
	return holder


func _install_anims(ap: AnimationPlayer) -> void:
	# Put the clips loaded from the separate Mixamo FBX files into a library
	# named "" so they are reachable as "idle"/"walk"/"run".
	var lib := AnimationLibrary.new()
	for key in _loaded_anims:
		lib.add_animation(key, _loaded_anims[key])
	if ap.has_animation_library(""):
		ap.remove_animation_library("")
	ap.add_animation_library("", lib)


func _tint_for(cid: int, c: Dictionary) -> Color:
	if cid == Net.detective_id:
		return DETECTIVE_TINT
	if c["resolved"]:
		return RESOLVED_AI_TINT if c["was_ai"] else RESOLVED_HUMAN_TINT
	# Per-character pastel variant, deterministic from the char id.
	return Color.from_hsv(fposmod(float(cid) * 0.137, 1.0), 0.30, 1.0)


func _tint_model(model_root: Node, tint: Color) -> void:
	# Solid per-character color: replace the surface material with a plain
	# colored material (the requested lightweight look, ignores PBR textures).
	for found in model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := found as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, _solid(tint))


func _solid(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.6
	return m


func _find_anim_player(model_root: Node) -> AnimationPlayer:
	var players := model_root.find_children("*", "AnimationPlayer", true, false)
	return players[0] as AnimationPlayer if not players.is_empty() else null


func _anim_name(ap: AnimationPlayer, kind: String) -> String:
	# Clips are installed as "idle"/"walk"/"run". Fall back to walk for run.
	var wanted: Array = [kind]
	if kind == "run":
		wanted.append("walk")
	elif kind == "walk":
		wanted.append("run")
	for k in wanted:
		if ap.has_animation(k):
			return k
		for anim_name in ap.get_animation_list():
			if String(anim_name).to_lower().ends_with(k):
				return anim_name
	var all := ap.get_animation_list()
	return all[0] if all.size() > 0 else ""


func _play_idle(ap: AnimationPlayer) -> void:
	var chosen := _anim_name(ap, "idle")
	if chosen.is_empty():
		return
	var anim := ap.get_animation(chosen)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR
	ap.play(chosen)
	# Random start offset so the crowd doesn't idle in perfect sync.
	if anim != null and anim.length > 0.0:
		ap.seek(randf() * anim.length, true)


func _set_anim(cid: int, kind: String) -> void:
	if not _char_anim.has(cid):
		return
	var ap: AnimationPlayer = _char_anim[cid]
	if not is_instance_valid(ap):
		return
	var chosen := _anim_name(ap, kind)
	if chosen.is_empty() or (ap.current_animation == chosen and ap.is_playing()):
		return
	var anim := ap.get_animation(chosen)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR
	ap.play(chosen, 0.15)


func _on_det_moved(pos: Vector3) -> void:
	# The local detective is driven by physics; ignore the echoed position so
	# we don't fight move_and_slide. Only remote viewers apply the position.
	if Net.my_char_id == Net.detective_id:
		return
	if _char_nodes.has(Net.detective_id):
		var node: Node3D = _char_nodes[Net.detective_id]
		var delta := pos - node.position
		delta.y = 0.0
		if delta.length() > 0.01:
			node.look_at(node.position + delta, Vector3.UP)
			_set_anim(Net.detective_id, "run")
			_det_move_cooldown = 0.25
		node.position = pos


# =====================================================================
# LOOP: matchmaking screen + detective movement + camera + interaction
# =====================================================================

func _process(delta: float) -> void:
	if is_instance_valid(_starfield):
		_starfield.rotate_y(STAR_SPIN_SPEED * delta)
	if _det_move_cooldown > 0.0:
		_det_move_cooldown -= delta
		if _det_move_cooldown <= 0.0:
			_set_anim(Net.detective_id, "idle")
	# Procedural floating for static (non-rigged) models.
	if not _char_visual.is_empty():
		var t := Time.get_ticks_msec() / 1000.0
		for cid in _char_visual:
			var v: Node3D = _char_visual[cid]
			if is_instance_valid(v):
				v.position.y = MODEL_Y_OFFSET + sin(t * BOB_SPEED + _bob_phase[cid]) * BOB_HEIGHT
	if _mm_root != null and _mm_root.visible:
		_mm_elapsed += delta
		while not _mm_times.is_empty() and _mm_elapsed >= float(_mm_times[0]):
			_mm_times.pop_front()
			_mm_found += 1
		var dots := ".".repeat(1 + int(_mm_elapsed) % 3)
		_mm_label.text = "Searching for players%s\n\n%d / %d players found" % [dots, _mm_found, _mm_total]


func _physics_process(delta: float) -> void:
	if Net.characters.is_empty():
		return
	var am_detective: bool = Net.my_char_id != -1 and Net.my_char_id == Net.detective_id
	if not am_detective:
		return

	var node := _char_nodes.get(Net.detective_id) as Node3D
	if not ui_chat.visible and node != null:
		var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
		if node is CharacterBody3D:
			# Real physics: slides along StaticBody walls.
			var body := node as CharacterBody3D
			body.velocity = Vector3(dir.x, 0.0, dir.y) * SPEED
			body.up_direction = Vector3.UP
			body.move_and_slide()
			body.position.y = _det_spawn_y
			_my_pos = body.position
		else:
			# Fallback (shouldn't normally happen): simple positional move.
			if dir != Vector2.ZERO:
				_my_pos += Vector3(dir.x, 0.0, dir.y) * SPEED * delta
				node.position = _my_pos
		if dir != Vector2.ZERO:
			node.look_at(node.position + Vector3(dir.x, 0.0, dir.y), Vector3.UP)
			_set_anim(Net.detective_id, "run")
			_det_move_cooldown = 0.2
			# Footstep cadence: play a step every STEP_INTERVAL while moving.
			_step_timer -= delta
			if _step_timer <= 0.0:
				_step_timer = STEP_INTERVAL
				Sfx.play(["footstep1", "footstep2", "footstep3"].pick_random())
		else:
			_step_timer = 0.0   # reset so the next step plays immediately
		_pos_timer += delta
		if _pos_timer >= 0.08:
			_pos_timer = 0.0
			Net.api_send_pos(_my_pos)

	_cam.position = _my_pos + Vector3(0.0, 9.0, 8.0)
	_cam.look_at(_my_pos + Vector3(0.0, 1.0, 0.0))
	_update_nearest()


func _update_nearest() -> void:
	_nearest = -1
	var best := Net.INTERACT_DIST
	for cid in Net.characters:
		if cid == Net.detective_id:
			continue
		var c: Dictionary = Net.characters[cid]
		if c["resolved"]:
			continue
		var d: float = (_my_pos - (c["pos"] as Vector3)).length()
		if d < best:
			best = d
			_nearest = cid
	if _nearest != -1 and not ui_chat.visible:
		ui_hint.text = "Press E to interrogate %s" % Net.characters[_nearest]["label"]
		ui_hint.visible = true
	else:
		ui_hint.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact") and _nearest != -1 and not ui_chat.visible:
		if Net.my_char_id == Net.detective_id:
			Net.api_request_chat(_nearest)


# =====================================================================
# UI
# =====================================================================

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	ui_status = Label.new()
	ui_status.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	ui_status.offset_top = 10.0
	ui_status.offset_left = 16.0
	ui_status.offset_right = -200.0
	ui_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	canvas.add_child(ui_status)

	ui_score = Label.new()
	ui_score.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	ui_score.offset_left = -180.0
	ui_score.offset_top = 10.0
	canvas.add_child(ui_score)

	ui_hint = Label.new()
	ui_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	ui_hint.offset_top = -120.0
	ui_hint.offset_bottom = -90.0
	ui_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui_hint.visible = false
	canvas.add_child(ui_hint)

	# ---------- Lobby ----------
	_lobby_root = CenterContainer.new()
	_lobby_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lobby_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_lobby_root)

	var panel := PanelContainer.new()
	_lobby_root.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 20)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380.0, 0.0)
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	var title := Label.new()
	title.text = "WHO IS AN AI?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Human or AI? The detective decides."
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.modulate = Color(1, 1, 1, 0.6)
	box.add_child(subtitle)

	ui_nickname = LineEdit.new()
	ui_nickname.placeholder_text = "Your nickname (optional)"
	box.add_child(ui_nickname)

	# Single "Play" button: it decides host-vs-join in the background.
	ui_btn_start = Button.new()
	ui_btn_start.text = "Play"
	box.add_child(ui_btn_start)
	ui_btn_start.pressed.connect(_on_play_pressed)
	ui_btn_start.mouse_entered.connect(func(): Sfx.play("hover"))

	# ---------- Fake matchmaking screen ----------
	_mm_root = CenterContainer.new()
	_mm_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mm_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mm_root.visible = false
	canvas.add_child(_mm_root)

	var mm_panel := PanelContainer.new()
	_mm_root.add_child(mm_panel)
	var mm_margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		mm_margin.add_theme_constant_override(side, 30)
	mm_panel.add_child(mm_margin)
	_mm_label = Label.new()
	_mm_label.custom_minimum_size = Vector2(320.0, 0.0)
	_mm_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mm_label.text = "Searching for players."
	mm_margin.add_child(_mm_label)

	# ---------- Chat panel ----------
	ui_chat = PanelContainer.new()
	ui_chat.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	ui_chat.offset_left = 30.0
	ui_chat.offset_right = -30.0
	ui_chat.offset_top = -310.0
	ui_chat.offset_bottom = -12.0
	ui_chat.visible = false
	canvas.add_child(ui_chat)

	var cmargin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		cmargin.add_theme_constant_override(side, 12)
	ui_chat.add_child(cmargin)
	var cbox := VBoxContainer.new()
	cbox.add_theme_constant_override("separation", 8)
	cmargin.add_child(cbox)

	ui_chat_header = Label.new()
	cbox.add_child(ui_chat_header)

	ui_chat_log = RichTextLabel.new()
	ui_chat_log.scroll_following = true
	ui_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cbox.add_child(ui_chat_log)

	ui_typing = Label.new()
	ui_typing.text = ""
	ui_typing.modulate = Color(1, 1, 1, 0.55)
	ui_typing.custom_minimum_size = Vector2(0.0, 22.0)
	cbox.add_child(ui_typing)

	var irow := HBoxContainer.new()
	irow.add_theme_constant_override("separation", 8)
	cbox.add_child(irow)
	ui_chat_input = LineEdit.new()
	ui_chat_input.placeholder_text = "Type a message..."
	ui_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	irow.add_child(ui_chat_input)
	var btn_send := Button.new()
	btn_send.text = "Send"
	irow.add_child(btn_send)

	ui_vote_box = HBoxContainer.new()
	ui_vote_box.add_theme_constant_override("separation", 8)
	cbox.add_child(ui_vote_box)
	var btn_ai := Button.new()
	btn_ai.text = "It's an AI"
	btn_ai.modulate = Color(1.0, 0.55, 0.55)
	btn_ai.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui_vote_box.add_child(btn_ai)
	var btn_human := Button.new()
	btn_human.text = "It's a human"
	btn_human.modulate = Color(0.55, 1.0, 0.6)
	btn_human.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui_vote_box.add_child(btn_human)
	var btn_close := Button.new()
	btn_close.text = "Close"
	ui_vote_box.add_child(btn_close)

	ui_chat_input.text_submitted.connect(_send_chat)
	ui_chat_input.text_changed.connect(_on_input_changed)
	btn_send.pressed.connect(func(): _send_chat(ui_chat_input.text))
	btn_ai.pressed.connect(func(): Net.api_vote(true))
	btn_human.pressed.connect(func(): Net.api_vote(false))
	btn_close.pressed.connect(func(): Net.api_close_chat())

	# ---------- Intro sequence overlay ----------
	_intro_root = ColorRect.new()
	_intro_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro_root.color = Color(0.03, 0.03, 0.05)
	_intro_root.visible = false
	canvas.add_child(_intro_root)
	var ic := CenterContainer.new()
	ic.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro_root.add_child(ic)
	_intro_label = Label.new()
	_intro_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_intro_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intro_label.custom_minimum_size = Vector2(620.0, 0.0)
	_intro_label.add_theme_font_size_override("font_size", 34)
	ic.add_child(_intro_label)


func _on_play_pressed() -> void:
	Sfx.play("click")
	Sfx.start_ambience()
	Sfx.start_bgm()
	if not _connected:
		# First press: connect (auto host-or-join decided in the background).
		ui_btn_start.disabled = true
		ui_btn_start.text = "Connecting..."
		ui_nickname.editable = false
		Net.play(ui_nickname.text.strip_edges(), Net.DEFAULT_ADDRESS)
	else:
		# Already connected: this press starts the match (fake matchmaking).
		Net.api_request_start()


func _on_connected() -> void:
	_connected = true
	ui_btn_start.disabled = false
	ui_btn_start.text = "Find match"
	Sfx.play("joined", -6.0)


func _on_matchmaking(duration: float, total: int) -> void:
	Sfx.play("intro")
	# The counter is timed so it reaches the REAL participant total slightly
	# before the match starts - what you see is exactly what spawns.
	_mm_elapsed = 0.0
	_mm_found = 1
	_mm_total = total
	_mm_times.clear()
	for i in range(total - 1):
		_mm_times.append(duration * randf_range(0.12, 0.92))
	_mm_times.sort()
	_lobby_root.visible = false
	_mm_root.visible = true


func _on_game_synced() -> void:
	_lobby_root.visible = false
	_mm_root.visible = false
	ui_chat.visible = false
	ui_typing.text = ""
	_typing_sent = false
	_chat_target = -1


func _on_my_id() -> void:
	# my_char_id is now known. The first _refresh_roster (from cl_sync) ran
	# while it was still -1, so the local detective was built as a plain Node3D.
	# Rebuild now so it becomes a CharacterBody3D and can actually move.
	_refresh_roster()
	_play_intro()


func _show_role_status() -> void:
	if Net.my_char_id == Net.detective_id:
		ui_status.text = "You are the DETECTIVE. Walk up to a subject (WASD) and press E."
	else:
		ui_status.text = "You are %s. If the detective questions you, convince them you are human!" % Net.characters.get(Net.my_char_id, {}).get("label", "a subject")


func _play_intro() -> void:
	if _intro_active:
		return
	_intro_active = true
	var lines := [
		"There are people in a room.",
		"Some of them are AI, some of them are real people",
		"Find who is an AI !",
	]
	_intro_root.visible = true
	_intro_root.modulate.a = 1.0
	for line in lines:
		await _intro_show_line(line)
	# Fade the whole overlay out.
	var tw := create_tween()
	tw.tween_property(_intro_root, "modulate:a", 0.0, 0.6)
	await tw.finished
	_intro_root.visible = false
	_intro_active = false
	_show_role_status()


func _intro_show_line(text: String) -> void:
	_intro_label.text = text
	Sfx.play("select")
	_intro_label.modulate.a = 0.0
	var tin := create_tween()
	tin.tween_property(_intro_label, "modulate:a", 1.0, 0.4)
	await tin.finished
	await get_tree().create_timer(1.4).timeout
	var tout := create_tween()
	tout.tween_property(_intro_label, "modulate:a", 0.0, 0.4)
	await tout.finished


# =====================================================================
# CHAT / TYPING / VERDICT
# =====================================================================

func _on_chat_opened(target_id: int) -> void:
	_chat_target = target_id
	Sfx.play("open_chat")
	ui_chat_log.clear()
	ui_typing.text = ""
	_typing_sent = false
	var am_det := Net.my_char_id == Net.detective_id
	if am_det:
		ui_chat_header.text = "Interrogating %s" % Net.characters[target_id]["label"]
	else:
		ui_chat_header.text = "The detective is questioning you..."
	ui_vote_box.visible = am_det
	ui_chat.visible = true
	ui_chat_input.grab_focus()


func _on_chat_closed() -> void:
	Sfx.play("close_chat")
	ui_chat.visible = false
	ui_typing.text = ""
	_typing_sent = false
	_chat_target = -1


func _send_chat(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	Net.api_chat(text)
	if _typing_sent:
		_typing_sent = false
		Net.api_typing(false)
	ui_chat_input.clear()
	ui_chat_input.grab_focus()


func _on_input_changed(text: String) -> void:
	if not ui_chat.visible:
		return
	var now_typing := not text.is_empty()
	if now_typing != _typing_sent:
		_typing_sent = now_typing
		Net.api_typing(now_typing)


func _on_chat_typing(from_detective: bool, typing: bool) -> void:
	if not ui_chat.visible:
		return
	if not typing:
		ui_typing.text = ""
		return
	var am_det := Net.my_char_id == Net.detective_id
	if am_det and not from_detective and _chat_target != -1 and Net.characters.has(_chat_target):
		ui_typing.text = "%s is typing..." % Net.characters[_chat_target]["label"]
	elif not am_det and from_detective:
		ui_typing.text = "Detective is typing..."


func _on_chat_msg(from_detective: bool, text: String) -> void:
	var am_det := Net.my_char_id == Net.detective_id
	# The other side's message just arrived: clear their typing indicator.
	if from_detective != am_det:
		ui_typing.text = ""
	var who: String
	if from_detective:
		who = "You" if am_det else "Detective"
	else:
		if am_det and _chat_target != -1 and Net.characters.has(_chat_target):
			who = str(Net.characters[_chat_target]["label"])
		else:
			who = "You"
	ui_chat_log.push_bold()
	ui_chat_log.add_text(who + ": ")
	ui_chat_log.pop()
	ui_chat_log.add_text(text + "\n")


func _on_verdict(target_id: int, was_ai: bool, correct: bool, guess_ai: bool) -> void:
	var label := str(Net.characters[target_id]["label"]) if Net.characters.has(target_id) else "The subject"
	var nature := "an AI" if was_ai else "a HUMAN"
	if Net.my_char_id == Net.detective_id:
		Sfx.play("correct" if correct else "wrong")
		if correct:
			ui_status.text = "Correct! %s really was %s. (+1 point)" % [label, nature]
		else:
			ui_status.text = "Wrong... %s was actually %s." % [label, nature]
	elif Net.my_char_id == target_id:
		if correct:
			ui_status.text = "The detective correctly identified you as %s." % nature
		else:
			ui_status.text = "You fooled the detective! They got your nature wrong (%s)." % nature
	else:
		ui_status.text = "%s has been identified: it was %s. (%s)" % [label, nature, "correct guess" if correct else "detective's mistake"]
	if ui_chat.visible:
		ui_chat.visible = false
		ui_typing.text = ""
	_chat_target = -1

	# When the detective declares someone an AI, throw them out of the ship -
	# regardless of their real identity. Purely visual, plays on every client.
	if guess_ai and _char_nodes.has(target_id) and target_id != Net.detective_id:
		_eject_character(target_id)


# Tunables for the eject gag.
const EJECT_LIFT_TIME := 0.45
const EJECT_FLY_TIME := 1.6
const EJECT_DISTANCE := 70.0
const EJECT_HEIGHT := 14.0
const EJECT_SPINS := 4.0

func _eject_character(cid: int) -> void:
	var node: Node3D = _char_nodes[cid]
	# Take ownership of the node so _refresh_roster won't touch it.
	_ejecting[cid] = true
	_char_anim.erase(cid)
	_char_visual.erase(cid)
	Sfx.play("eject")

	var start: Vector3 = node.position
	# Throw outward from the room center, with an upward arc.
	var outward := Vector3(start.x, 0.0, start.z)
	if outward.length() < 0.5:
		outward = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0)
	outward = outward.normalized()
	var target := start + outward * EJECT_DISTANCE + Vector3(0, EJECT_HEIGHT * 0.3, 0)

	var tw := create_tween()
	tw.set_parallel(false)
	# 1) Quick lift + a little squash, like being grabbed.
	tw.tween_property(node, "position:y", start.y + 2.2, EJECT_LIFT_TIME) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# 2) Fling outward in an arc while spinning and shrinking.
	tw.set_parallel(true)
	tw.chain().tween_property(node, "position:x", target.x, EJECT_FLY_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(node, "position:z", target.z, EJECT_FLY_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# Vertical arc: up then down past the floor (out of the open roof feel).
	tw.tween_method(
		func(t: float): node.position.y = lerpf(start.y + 2.2, start.y - 6.0, t) + sin(t * PI) * EJECT_HEIGHT,
		0.0, 1.0, EJECT_FLY_TIME)
	tw.tween_property(node, "rotation:x", node.rotation.x + TAU * EJECT_SPINS, EJECT_FLY_TIME)
	tw.tween_property(node, "rotation:z", node.rotation.z + TAU * (EJECT_SPINS * 0.5), EJECT_FLY_TIME)
	tw.tween_property(node, "scale", Vector3.ONE * 0.15, EJECT_FLY_TIME) \
		.set_ease(Tween.EASE_IN)

	await tw.finished
	if is_instance_valid(node):
		node.queue_free()
	_char_nodes.erase(cid)
	_ejecting.erase(cid)


func _on_game_over(sc: int, total: int) -> void:
	Sfx.play("gameover")
	ui_status.text = "Game over! Detective's score: %d / %d" % [sc, total]
	ui_btn_start.text = "Find new match"
	ui_btn_start.disabled = false
	_lobby_root.visible = true
