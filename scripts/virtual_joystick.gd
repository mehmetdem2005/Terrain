extends Control
# =====================================================================
#  SANAL JOYSTICK  -  Mobil dokunma + masaustu fare ile test edilebilir
#  Kendi dikdortgeni icinde parmak/fare basinca taban orada belirir
#  (floating tip), surukleyince yon verir. get_value() -> Vector2 (-1..1)
# =====================================================================

@export var max_radius: float = 120.0   # knob'un tabandan azami uzakligi (px)
@export var dead_zone: float = 0.12      # bu degerin altindaki girdi 0 sayilir
@export var base_color: Color = Color(1, 1, 1, 0.18)
@export var knob_color: Color = Color(1, 1, 1, 0.42)

var _value: Vector2 = Vector2.ZERO
var _index: int = -99      # -99 yok, -1 fare, >=0 dokunma parmagi
var _base: Vector2 = Vector2.ZERO
var _knob: Vector2 = Vector2.ZERO


func _ready() -> void:
	add_to_group("vjoystick")
	mouse_filter = Control.MOUSE_FILTER_PASS


## Hareket girdisi: x = sag(+)/sol(-), y = ileri(+)/geri(-)
func get_value() -> Vector2:
	return _value


## Kameranin yok sayacagi (joystick'in kullandigi) dokunma parmagi
func get_active_index() -> int:
	return _index


func _in_zone(p: Vector2) -> bool:
	return Rect2(global_position, size).has_point(p)


func _input(event: InputEvent) -> void:
	var pos: Vector2
	var idx: int
	var pressed: bool
	var is_press_or_release := false

	if event is InputEventScreenTouch:
		pos = event.position
		idx = event.index
		pressed = event.pressed
		is_press_or_release = true
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		idx = -1
		pressed = event.pressed
		is_press_or_release = true
	elif event is InputEventScreenDrag and event.index == _index:
		_drag(event.position)
		return
	elif event is InputEventMouseMotion and _index == -1:
		_drag(event.position)
		return
	else:
		return

	if is_press_or_release:
		if pressed and _index == -99 and _in_zone(pos):
			_index = idx
			_base = pos
			_knob = pos
			_value = Vector2.ZERO
			queue_redraw()
			get_viewport().set_input_as_handled()
		elif not pressed and idx == _index:
			_index = -99
			_value = Vector2.ZERO
			queue_redraw()


func _drag(p: Vector2) -> void:
	var off := p - _base
	if off.length() > max_radius:
		off = off.normalized() * max_radius
	_knob = _base + off
	var v := off / max_radius
	if v.length() < dead_zone:
		v = Vector2.ZERO
	# ekran y asagi pozitif -> ileri(+) icin ters cevir
	_value = Vector2(v.x, -v.y)
	queue_redraw()


func _draw() -> void:
	if _index == -99:
		return
	var c := _base - global_position
	draw_circle(c, max_radius, base_color)
	draw_circle(_knob - global_position, max_radius * 0.42, knob_color)
