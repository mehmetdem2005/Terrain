extends Camera3D
# =====================================================================
#  FLY CAMERA  -  Basit serbest ucus kamerasi (test / demo amacli)
#  Sag tik basili: etrafa bak | WASD: hareket | Q/E: alcal/yuksel
#  Shift: hizli mod. Mobil dokunma kontrolu yerine gececek gecici cozum.
# =====================================================================

@export var move_speed: float = 30.0
@export var sprint_mult: float = 4.0
@export var look_sensitivity: float = 0.0025

var _yaw: float = 0.0
var _pitch: float = 0.0
var _looking: bool = false


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_looking = event.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking \
				else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and _looking:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S): dir += transform.basis.z
	if Input.is_key_pressed(KEY_A): dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D): dir += transform.basis.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir += Vector3.DOWN

	var spd := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		spd *= sprint_mult
	if dir != Vector3.ZERO:
		global_position += dir.normalized() * spd * delta
