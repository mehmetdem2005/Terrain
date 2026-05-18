extends CharacterBody3D
# =====================================================================
#  TEST OYUNCU  -  kapsul govde + ucuncu sahis kamera + kontrol
#  Masaustu : WASD/oklar yuru, Shift kos, Space zipla, sol tik fare
#             kilitle (bakis), ESC birak.
#  Mobil    : sol-alt sanal joystick yuru, sag yari surukle bakis,
#             ZIPLA dugmesi.
#  Arazi = Terrain3D dugumu ("terrain" grubu). Collision Terrain3D'nin
#  kendi runtime collision'i ile (CharacterBody3D mask 1). Spawn'da
#  Terrain3D.data.get_height ile yere oturulur.
# =====================================================================

@export var move_speed: float = 14.0
@export var sprint_mult: float = 2.2
@export var jump_velocity: float = 9.0
@export var gravity: float = 26.0
@export var mouse_sensitivity: float = 0.0026
@export var touch_sensitivity: float = 0.0050
@export var min_pitch: float = -1.30
@export var max_pitch: float = 0.45
## Spawn icin dunya (x,z). auto_center acikken (0,0) arazinin ortasidir.
@export var spawn_xz: Vector2 = Vector2(0.0, 0.0)
@export var spawn_clearance: float = 4.0

@onready var _pivot: Node3D = $CameraPivot
@onready var _mesh: Node3D = $Mesh

var _yaw: float = 0.0
var _pitch: float = -0.35
var _joystick: Control = null
var _mgr: Node = null


func _ready() -> void:
	# ONEMLI: joystick/jumpbtn kendilerini _ready'de gruba ekler ve sahne
	# agacinda Player onlardan ONCE _ready olur. Bu yuzden referanslari
	# _ready'nin BASINDA almak null verir. Iki kareyi bekleyip sonra al.
	await get_tree().process_frame
	await get_tree().process_frame
	_mgr = get_tree().get_first_node_in_group("terrain")
	var jb := get_tree().get_first_node_in_group("jumpbtn")
	if jb != null and jb.has_signal("pressed") \
			and not jb.pressed.is_connected(_try_jump):
		jb.pressed.connect(_try_jump)
	_snap_to_ground()


## Joystick'i tembel coz (sira/zamanlama ne olursa olsun guvenli).
func _get_joystick() -> Control:
	if _joystick == null or not is_instance_valid(_joystick):
		_joystick = get_tree().get_first_node_in_group("vjoystick") as Control
	return _joystick


func _snap_to_ground() -> void:
	var h := 0.0
	if _mgr != null and "data" in _mgr and _mgr.data != null:
		var gh: float = _mgr.data.get_height(
			Vector3(spawn_xz.x, 0.0, spawn_xz.y))
		if not is_nan(gh):
			h = gh
	global_position = Vector3(spawn_xz.x, h + spawn_clearance, spawn_xz.y)
	velocity = Vector3.ZERO


func _try_jump() -> void:
	if is_on_floor():
		velocity.y = jump_velocity


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed \
			and e.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif e is InputEventMouseMotion \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look(-e.relative.x * mouse_sensitivity,
			   -e.relative.y * mouse_sensitivity)
	elif e is InputEventScreenDrag:
		# sag yari = kamera bakis (joystick'in kullandigi parmak haric)
		var ji := -123
		var js := _get_joystick()
		if js != null and js.has_method("get_active_index"):
			ji = js.get_active_index()
		var half := get_viewport().get_visible_rect().size.x * 0.5
		if e.index != ji and e.position.x > half:
			_look(-e.relative.x * touch_sensitivity,
				  -e.relative.y * touch_sensitivity)


func _look(dyaw: float, dpitch: float) -> void:
	_yaw = wrapf(_yaw + dyaw, -PI, PI)
	_pitch = clampf(_pitch + dpitch, min_pitch, max_pitch)


func _move_input() -> Vector2:
	# klavye
	var v := Vector2.ZERO
	if Input.is_action_pressed("move_forward"):  v.y += 1.0
	if Input.is_action_pressed("move_back"):     v.y -= 1.0
	if Input.is_action_pressed("move_left"):     v.x -= 1.0
	if Input.is_action_pressed("move_right"):    v.x += 1.0
	# joystick (varsa ekle) - tembel coz
	var js := _get_joystick()
	if js != null and js.has_method("get_value"):
		v += js.get_value()
	if v.length() > 1.0:
		v = v.normalized()
	return v


func _physics_process(dt: float) -> void:
	# kamera donusu
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)

	var mv := _move_input()
	var fwd := -Vector3(sin(_yaw), 0.0, cos(_yaw))   # _yaw yonu
	var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var dir := (fwd * mv.y + right * mv.x)
	if dir.length() > 1.0:
		dir = dir.normalized()

	var spd := move_speed
	if Input.is_action_pressed("sprint"):
		spd *= sprint_mult

	velocity.x = dir.x * spd
	velocity.z = dir.z * spd

	if is_on_floor():
		if Input.is_action_pressed("jump"):
			velocity.y = jump_velocity
		elif velocity.y < 0.0:
			velocity.y = -2.0
	else:
		velocity.y -= gravity * dt

	move_and_slide()

	# govde, gittigi yone donsun
	if dir.length() > 0.05:
		var target_y := atan2(-dir.x, -dir.z)
		_mesh.rotation.y = lerp_angle(_mesh.rotation.y, target_y, 12.0 * dt)
