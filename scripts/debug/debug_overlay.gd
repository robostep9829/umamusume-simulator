class_name DebugOverlay
extends CanvasLayer

## In-game debug overlay: what the biome system is doing, next to the frame,
## player and track numbers it is usually read with.
##
## Add it to a level as a [CanvasLayer] with this script attached. It finds the
## level's [TrackManager], [BiomeDirector] and player by itself; both can also be
## assigned in the inspector:
## [codeblock]
## [node name="DebugOverlay" type="CanvasLayer" parent="."]
## script = ExtResource("...")
## [/codeblock]
##
## [b]F3[/b] shows and hides the panel, [b]F4[/b] cycles how much it shows. On a
## touchscreen a small button in the top-right corner opens it instead. The panel
## never takes input, so it cannot swallow the game's own controls, and its width
## is fixed so the readout does not twitch as the numbers change.

## How much the panel shows, in the order of [constant DETAIL_NAMES].
enum Detail {
	## Frame rate, the biome, the next biome and the distance run.
	COMPACT,
	## Plus the player, the track and the atmosphere.
	NORMAL,
	## Plus layer instance counts, the horizon ring and render monitors.
	FULL,
}

const DETAIL_NAMES: Array[String] = ["compact", "normal", "full"]
const DEFAULT_UPDATE_INTERVAL := 0.1
const LABEL_WIDTH := 7
const PANEL_WIDTH := 440.0
const PANEL_COLOR := Color(0.03, 0.045, 0.06, 0.78)
const BORDER_COLOR := Color(1.0, 1.0, 1.0, 0.12)
const BAR_BACKGROUND := Color(1.0, 1.0, 1.0, 0.10)
const BAR_FILL := Color(0.36, 0.72, 0.48)
const LABEL_COLOR := "#7f8fa6"
const VALUE_COLOR := "#e6edf3"
const ACCENT_COLOR := "#79c0ff"
const GOOD_COLOR := "#7ee787"
const WARN_COLOR := "#e3b341"

## Track to report on. Auto-detected in the level when left empty.
@export var track: TrackManager
## Biomes to report on. Auto-detected in the level when left empty.
@export var director: BiomeDirector
## Runner the distances are measured from. Defaults to the track's own player.
@export var player: Node3D
## Panel state when the level starts.
@export var open_on_start := true
## How much to show; the names follow [enum Detail], which F4 cycles.
@export_enum("compact", "normal", "full") var detail: int = Detail.NORMAL
## Seconds between readouts. A debug panel does not need to run at frame rate, and
## rebuilding the text is the only work it does.
@export var update_interval := DEFAULT_UPDATE_INTERVAL

var _panel: PanelContainer
var _text: RichTextLabel
var _bar: ProgressBar
var _toggle: Button
var _elapsed := 0.0
# Rebuilt by _refresh() and read by the line builders, so the director is asked
# for its state once per refresh rather than once per line.
var _stats: Dictionary = {}


func _ready() -> void:
	# Above the level's own UI, and live while the game is paused: a debug panel
	# is most useful exactly when something is stuck.
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_resolve_targets()
	_set_panel_open(open_on_start)


func _process(delta: float) -> void:
	if not is_panel_open():
		return
	_elapsed += delta
	if _elapsed < update_interval:
		return
	_elapsed = 0.0
	refresh()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F3:
		toggle()
	elif key.keycode == KEY_F4:
		cycle_detail()
	else:
		return
	get_viewport().set_input_as_handled()


## True while the readout is showing.
func is_panel_open() -> bool:
	return _panel != null and _panel.visible


## Shows the readout if it is hidden, hides it otherwise.
func toggle() -> void:
	_set_panel_open(not is_panel_open())


## Moves to the next detail level, wrapping around.
func cycle_detail() -> void:
	detail = (detail + 1) % DETAIL_NAMES.size()
	refresh()


## Rebuilds the readout now, instead of on the next tick.
func refresh() -> void:
	if _panel == null or not is_panel_open():
		return
	if director != null:
		_stats = director.debug_stats()
	var lines: Array[String] = []
	lines.append(_header_line())
	_add_frame_lines(lines)
	if detail >= Detail.NORMAL:
		_add_track_lines(lines)
	_add_player_lines(lines)
	_add_biome_lines(lines)
	_add_fog_lines(lines)
	if detail >= Detail.FULL:
		_add_extra_lines(lines)
	lines.append(_hint_line())
	_text.text = "\n".join(PackedStringArray(lines))


# --- Building -----------------------------------------------------------------

func _build_ui() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["monospace", "DejaVu Sans Mono", "Consolas", "Courier New"])

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_panel.position = Vector2(12.0, 12.0)
	root.add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_panel.add_child(column)

	_text = RichTextLabel.new()
	_text.name = "Readout"
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.selection_enabled = true
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	_text.add_theme_font_override("normal_font", font)
	_text.add_theme_font_override("bold_font", font)
	_text.add_theme_font_override("mono_font", font)
	_text.add_theme_font_size_override("normal_font_size", 13)
	_text.add_theme_font_size_override("bold_font_size", 13)
	_text.add_theme_font_size_override("mono_font_size", 13)
	column.add_child(_text)

	_bar = ProgressBar.new()
	_bar.name = "BiomeRun"
	_bar.show_percentage = false
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.custom_minimum_size = Vector2(0.0, 5.0)
	_bar.add_theme_stylebox_override("background", _bar_style(BAR_BACKGROUND))
	_bar.add_theme_stylebox_override("fill", _bar_style(BAR_FILL))
	column.add_child(_bar)

	# A touchscreen has no F3, so the panel needs something to open it.
	_toggle = Button.new()
	_toggle.name = "Toggle"
	_toggle.text = "dbg"
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.visible = DisplayServer.is_touchscreen_available()
	_toggle.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_toggle.position = Vector2(-72.0, 12.0)
	_toggle.custom_minimum_size = Vector2(60.0, 36.0)
	_toggle.pressed.connect(toggle)
	root.add_child(_toggle)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.border_color = BORDER_COLOR
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	return style


func _bar_style(colour: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = colour
	style.set_corner_radius_all(2)
	return style


func _set_panel_open(open: bool) -> void:
	if _panel == null:
		return
	_panel.visible = open
	if open:
		refresh()


func _resolve_targets() -> void:
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	if director == null:
		director = _find_director(root)
	if track == null and director != null:
		track = director.track
	if track == null:
		track = _find_track(root)
	if player == null and track != null:
		player = track.player
	if player == null:
		player = _find_runner(root)


## The level's biome plumbing, depth first. Typed `is` checks rather than
## `Node.is_class()`, which ignores script `class_name` declarations.
func _find_director(root: Node) -> BiomeDirector:
	for child in root.get_children():
		if child is BiomeDirector:
			return child
		var found := _find_director(child)
		if found != null:
			return found
	return null


func _find_track(root: Node) -> TrackManager:
	for child in root.get_children():
		if child is TrackManager:
			return child
		var found := _find_track(child)
		if found != null:
			return found
	return null


func _find_runner(root: Node) -> Node3D:
	for child in root.get_children():
		if child is CharacterBody3D:
			return child
		var found := _find_runner(child)
		if found != null:
			return found
	return null


# --- Lines --------------------------------------------------------------------

func _header_line() -> String:
	return "[color=%s]DEBUG[/color] [color=%s]%s[/color]" % [
		ACCENT_COLOR, LABEL_COLOR, DETAIL_NAMES[clampi(detail, 0, DETAIL_NAMES.size() - 1)]
	]


func _hint_line() -> String:
	return "[color=%s]F3[/color] [color=%s]hide · F4 detail[/color]" % [LABEL_COLOR, LABEL_COLOR]


func _add_frame_lines(lines: Array[String]) -> void:
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	lines.append(_field("fps", "%s   frame %s ms   physics %s ms" % [
		_thousands(Performance.get_monitor(Performance.TIME_FPS)),
		String.num(frame_ms, 2),
		String.num(physics_ms, 2),
	]))
	if detail < Detail.FULL:
		return
	lines.append(_field("render", "%d draws   %d objects   %d nodes   %s MiB" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		String.num(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 1),
	]))


func _add_track_lines(lines: Array[String]) -> void:
	if track == null:
		lines.append(_field("track", "no TrackManager in this level", WARN_COLOR))
		return
	if track.is_endless():
		lines.append(_field("track", "endless · pool %d · seed %d" % [
			track.pool_size, track.infinite_seed
		]))
		return
	var lap := "%s · %d elements · pool %d" % [
		_metres(track.lap_length()), track.track_level.count(), track.pool_size
	]
	lines.append(_field("track", "closed loop %s" % lap))


func _add_player_lines(lines: Array[String]) -> void:
	if player == null:
		lines.append(_field("player", "not found", WARN_COLOR))
		return
	var speed := _player_speed()
	lines.append(_field("speed", "%s m/s · %s" % [String.num(speed, 1), _kmh(speed)]))
	var position := player.global_position
	lines.append(_field("pos", "%s, %s, %s" % [
		_thousands(position.x), _thousands(position.y), _thousands(position.z)
	]))
	if track == null:
		return
	var distance := track.track_distance_at(position)
	var element := track.element_index_at(position)
	var text := _metres(distance)
	if not track.is_endless() and track.lap_length() > 0.0:
		var lap := int(floor(distance / track.lap_length()))
		var remaining := track.lap_length() - fmod(distance, track.lap_length())
		text += "   lap %d · %s to go" % [lap, _metres(remaining)]
	lines.append(_field("s", text))
	lines.append(_field("element", "%d · %s · %d%% in" % [
		element, _element_name(element), int(round(track.element_progress_at(position) * 100.0))
	]))


func _add_biome_lines(lines: Array[String]) -> void:
	if director == null:
		lines.append(_field("biome", "no BiomeDirector in this level", WARN_COLOR))
		_bar.value = 0.0
		return
	var biome := String(_stats.get("biome", &"<none>"))
	var biome_name := String(_stats.get("biome_name", ""))
	var title := biome if biome_name.is_empty() else "%s · %s" % [biome, biome_name]
	lines.append(_field("biome", title, GOOD_COLOR))

	# An authoring problem is reported in the console, which a phone or a released
	# build does not show: the count here is what makes it visible in the game, and
	# it is shown at every detail level for the same reason.
	var problems := int(_stats.get("problems", 0))
	if problems > 0:
		lines.append(_field("issues", "%d · see the Output panel" % problems, WARN_COLOR))

	var change := float(_stats.get("change_distance", -1.0))
	if change < 0.0:
		lines.append(_field("next", "this biome runs the whole track"))
		_bar.value = 0.0
		return
	var text := "%s in %s" % [String(_stats.get("next_biome", &"<none>")), _metres(change)]
	var speed := _player_speed()
	if speed >= 1.0:
		text += " · %d s" % int(round(change / speed))
	text += " · %d elements" % int(_stats.get("change_elements", 0))
	lines.append(_field("next", text))
	_bar.value = float(_stats.get("run_progress", 0.0)) * 100.0


## The fog the world is rendering *right now*. Read from the live environment
## rather than from the biome's file, because during a transition those differ -
## and the fog is where a biome change is easiest to see, so it is worth a line of
## its own at every detail level.
##
## `fog_enabled` is the environment asset's own switch and nothing here or in the
## director writes to it, so a fog that is off is reported as the setting it is
## rather than as a problem.
func _add_fog_lines(lines: Array[String]) -> void:
	var environment := director.live_environment() if director != null else null
	if environment == null:
		lines.append(_field("fog", "no WorldEnvironment in this level", WARN_COLOR))
		return
	if not environment.fog_enabled:
		lines.append(_field("fog", "off - this environment leaves it off"))
		return
	var colour := environment.fog_light_color
	lines.append(_field("fog", "%s %s   density %s   energy %s" % [
		_swatch(colour), colour.to_html(false),
		String.num(environment.fog_density, 4),
		String.num(environment.fog_light_energy, 2),
	]))
	lines.append(_field("", "sky %s   aerial %s   sun %s" % [
		String.num(environment.fog_sky_affect, 2),
		String.num(environment.fog_aerial_perspective, 2),
		String.num(environment.fog_sun_scatter, 2),
	]))


func _add_extra_lines(lines: Array[String]) -> void:
	if director == null:
		return
	var layers := _stats.get("layers", {}) as Dictionary
	lines.append(_field("layers", "near %d · mid %d · far %d" % [
		int(layers.get("near", 0)), int(layers.get("mid", 0)), int(layers.get("far", 0))
	]))
	lines.append(_field("horizon", "%d cards · %s away" % [
		int(_stats.get("horizon_cards", 0)), _metres(float(_stats.get("horizon_distance", 0.0)))
	]))
	var build := _stats.get("build", {}) as Dictionary
	if not build.is_empty():
		lines.append(_field("build", "%d seg · %d inst · %s ms" % [
			int(build.get("segments", 0)), int(build.get("instances", 0)),
			String.num(float(build.get("usec", 0)) / 1000.0, 1)
		]))
	lines.append(_field("skin", "variant %d of %d" % [
		int(_stats.get("variant", 0)) + 1, int(_stats.get("variants", 1))
	]))
	var atmosphere := String(_stats.get("atmosphere", ""))
	lines.append(_field("atmo", "%s%s" % [
		atmosphere if not atmosphere.is_empty() else "level default", _fade_text()
	]))
	lines.append(_field("playlist", String(_stats.get("playlist", ""))))
	var upcoming := _stats.get("upcoming", []) as Array
	if not upcoming.is_empty():
		var parts := PackedStringArray()
		for run in upcoming:
			parts.append("%s ×%d" % [run["id"], run["elements"]])
		lines.append(_field("coming", " → ".join(parts)))


# --- Formatting ---------------------------------------------------------------

func _field(label: String, value: String, colour: String = VALUE_COLOR) -> String:
	return "[color=%s]%s[/color][color=%s]%s[/color]" % [
		LABEL_COLOR, _pad(label), colour, value
	]


func _pad(text: String, width: int = LABEL_WIDTH) -> String:
	var missing := width - text.length()
	return text + " ".repeat(missing if missing > 0 else 0)


## A number with one decimal and a space every three digits, so that a distance
## like 98 765.4 m can be read at a glance.
func _thousands(value: float) -> String:
	var parts := String.num(absf(value), 1).split(".")
	var whole := parts[0]
	var grouped := ""
	while whole.length() > 3:
		grouped = " " + whole.right(3) + grouped
		whole = whole.left(whole.length() - 3)
	grouped = whole + grouped
	var text := grouped if parts.size() < 2 else "%s.%s" % [grouped, parts[1]]
	return ("-" if value < 0.0 else "") + text


## A colour as a block the eye can compare between readouts.
func _swatch(colour: Color) -> String:
	return "[bgcolor=#%s]    [/bgcolor]" % colour.to_html(false)


## How far the atmosphere transition has come, or an empty string when none is
## running - so the readout tells "the fog is this colour" from "the fog is on its
## way to this colour".
func _fade_text() -> String:
	if director == null:
		return ""
	var progress := director.blend_progress()
	if progress >= 1.0:
		return ""
	return " \u00b7 fading %d%%" % int(round(progress * 100.0))


func _metres(value: float) -> String:
	return "%s m" % _thousands(value)


## A speed in km/h: the game's own numbers are m/s, and 21 m/s is 76 km/h, which is
## the unit a road reads in.
func _kmh(speed: float) -> String:
	return "%s km/h" % String.num(speed * 3.6, 1)


func _player_speed() -> float:
	var body := player as CharacterBody3D
	return body.velocity.length() if body != null else 0.0


func _element_name(element_index: int) -> String:
	if track == null:
		return "?"
	var direction := track.element_direction_at(element_index)
	if direction == 0:
		return "straight"
	return "right turn" if direction > 0 else "left turn"
