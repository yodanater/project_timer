package main

import rl "vendor:raylib"

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

WINDOW_WIDTH  :: 200
WINDOW_HEIGHT :: 200
NAV_HEIGHT    :: 24
STATE_PATH    :: "timer_state.txt"

MILLISECOND :: i64(1)
SECOND      :: i64(1000) * MILLISECOND
MINUTE      :: i64(60) * SECOND
HOUR        :: i64(60) * MINUTE
DAY         :: i64(24) * HOUR
YEAR        :: i64(365) * DAY

BG          :: rl.Color{15, 27, 43, 255}
NAV_BG      :: rl.Color{20, 39, 58, 255}
PANEL       :: rl.Color{24, 46, 67, 255}
PANEL_LIGHT :: rl.Color{31, 58, 81, 255}
BLUE        :: rl.Color{54, 105, 132, 255}
BLUE_LIGHT  :: rl.Color{91, 149, 174, 255}
ORANGE      :: rl.Color{205, 116, 60, 255}
ORANGE_DARK :: rl.Color{136, 68, 39, 255}
YELLOW      :: rl.Color{244, 196, 79, 255}
TEXT        :: rl.Color{232, 229, 216, 255}
MUTED       :: rl.Color{124, 151, 164, 255}
SHADOW      :: rl.Color{4, 10, 18, 175}
DANGER      :: rl.Color{220, 92, 70, 255}

Tab :: enum {
	Home,
	History,
}

Click_Target :: enum {
	Background,
	Timer,
	Home_Tab,
	History_Tab,
	Recent_Clear,
	Range_14_Days,
	Range_30_Days,
	Range_90_Days,
	Range_365_Days,
	Graph,
	Delete_Session,
}

Session :: struct {
	id:       i64,
	start_ms: i64,
	end_ms:   i64,
}

Click_Record :: struct {
	timestamp_ms: i64,
	x:            i32,
	y:            i32,
	target:       Click_Target,
}

App_State :: struct {
	running:                bool,
	accumulated_ms:         i64,
	run_started_ms:         i64,
	recent_cleared_until_ms: i64,
	next_session_id:        i64,
	sessions:               [dynamic]Session,
	clicks:                 [dynamic]Click_Record,
}

UI_State :: struct {
	tab:                 Tab,
	button_armed:        bool,
	range_days:          int,
	recent_scroll:       int,
	selected_session_id: i64,
}

BUTTON_CENTER :: rl.Vector2{100, 83}
BUTTON_RADIUS :: f32(49)
BUTTON_TEXTURE_SIZE :: f32(112)

GRAPH_RECT  :: rl.Rectangle{8, 49, 184, 86}
DELETE_RECT :: rl.Rectangle{137, 179, 55, 16}
CLEAR_RECT  :: rl.Rectangle{155, 144, 37, 13}

RANGE_DAYS:   [4]int = {14, 30, 90, 365}
RANGE_LABELS: [4]cstring = {"2W", "1M", "3M", "1Y"}

BUTTON_FRAGMENT_SHADER :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float u_pressed;
uniform float u_hovered;
out vec4 finalColor;

void main() {
    vec4 mask = texture(texture0, fragTexCoord);
    if (mask.a < 0.02) discard;

    vec2 p = fragTexCoord * 2.0 - 1.0;
    p.y += u_pressed * 0.085;
    float r2 = dot(p, p);
    float z = sqrt(max(0.0, 1.0 - r2));
    vec3 normal = normalize(vec3(p.x * 0.88, p.y * 0.88, z));
    vec3 lightDir = normalize(vec3(-0.65, -0.82, 1.35));
    float diffuse = max(dot(normal, lightDir), 0.0);
    float rim = smoothstep(0.58, 1.0, sqrt(r2));
    float topGlow = smoothstep(0.40, -0.85, p.y) * (1.0 - rim);

    vec3 deepBlue = vec3(0.075, 0.205, 0.300);
    vec3 softBlue = vec3(0.245, 0.490, 0.610);
    vec3 warmOrange = vec3(0.805, 0.355, 0.145);
    vec3 color = mix(deepBlue, softBlue, 0.20 + diffuse * 0.72);
    color = mix(color, warmOrange, rim * (0.14 + max(-p.y, 0.0) * 0.16));
    color += vec3(0.12, 0.09, 0.045) * topGlow;
    color += u_hovered * vec3(0.035, 0.045, 0.025);
    color *= 1.0 - u_pressed * 0.22;

    finalColor = vec4(color, mask.a * colDiffuse.a * fragColor.a);
}`

now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

elapsed_ms :: proc(state: ^App_State, current_ms: i64) -> i64 {
	result := state.accumulated_ms
	if state.running && state.run_started_ms > 0 {
		result += max(i64(0), current_ms - state.run_started_ms)
	}
	return result
}

point_in_circle :: proc(point, center: rl.Vector2, radius: f32) -> bool {
	dx := point.x - center.x
	dy := point.y - center.y
	return dx*dx + dy*dy <= radius*radius
}

format_duration :: proc(duration_ms: i64) -> cstring {
	total_seconds := max(i64(0), duration_ms) / SECOND
	hours := total_seconds / 3600
	minutes := (total_seconds / 60) % 60
	seconds := total_seconds % 60
	if hours >= 100 {
		return fmt.ctprintf("%dh %02dm", hours, minutes)
	}
	return fmt.ctprintf("%02d:%02d:%02d", hours, minutes, seconds)
}

format_short_duration :: proc(duration_ms: i64) -> cstring {
	total_seconds := max(i64(0), duration_ms) / SECOND
	hours := total_seconds / 3600
	minutes := (total_seconds / 60) % 60
	seconds := total_seconds % 60
	if hours > 0 {
		return fmt.ctprintf("%dh %02dm", hours, minutes)
	}
	if minutes > 0 {
		return fmt.ctprintf("%dm %02ds", minutes, seconds)
	}
	return fmt.ctprintf("%ds", seconds)
}

format_date_time :: proc(timestamp_ms: i64) -> cstring {
	t := time.unix(timestamp_ms / SECOND, 0)
	year, month, day := time.date(t)
	hour, minute, _ := time.clock_from_time(t)
	return fmt.ctprintf("%02d/%02d/%02d %02d:%02d UTC", int(month), day, year % 100, hour, minute)
}

format_short_date :: proc(timestamp_ms: i64) -> cstring {
	t := time.unix(timestamp_ms / SECOND, 0)
	_, month, day := time.date(t)
	return fmt.ctprintf("%02d/%02d", int(month), day)
}

format_clock :: proc(timestamp_ms: i64) -> cstring {
	t := time.unix(timestamp_ms / SECOND, 0)
	hour, minute, _ := time.clock_from_time(t)
	return fmt.ctprintf("@ %02d:%02d UTC", hour, minute)
}

format_session_span :: proc(start_ms, end_ms: i64) -> cstring {
	start_time := time.unix(start_ms / SECOND, 0)
	end_time := time.unix(end_ms / SECOND, 0)
	_, start_month, start_day := time.date(start_time)
	_, end_month, end_day := time.date(end_time)
	start_hour, start_minute, _ := time.clock_from_time(start_time)
	end_hour, end_minute, _ := time.clock_from_time(end_time)
	return fmt.ctprintf(
		"%02d/%02d %02d:%02d > %02d/%02d %02d:%02d UTC",
		int(start_month),
		start_day,
		start_hour,
		start_minute,
		int(end_month),
		end_day,
		end_hour,
		end_minute,
	)
}

draw_centered_text :: proc(text: cstring, center_x: f32, y: i32, size: i32, color: rl.Color) {
	width := rl.MeasureText(text, size)
	rl.DrawText(text, i32(center_x)-width/2, y, size, color)
}

record_click :: proc(state: ^App_State, mouse: rl.Vector2, target: Click_Target) {
	append(&state.clicks, Click_Record{
		timestamp_ms = now_ms(),
		x = i32(mouse.x),
		y = i32(mouse.y),
		target = target,
	})
}

toggle_timer :: proc(state: ^App_State, current_ms: i64) {
	if state.running {
		duration := max(i64(0), current_ms - state.run_started_ms)
		state.accumulated_ms += duration
		if duration > 0 {
			append(&state.sessions, Session{
				id = state.next_session_id,
				start_ms = state.run_started_ms,
				end_ms = current_ms,
			})
			state.next_session_id += 1
		}
		state.running = false
		state.run_started_ms = 0
	} else {
		state.running = true
		state.run_started_ms = current_ms
	}
}

clicks_during :: proc(state: ^App_State, start_ms, end_ms: i64) -> int {
	count := 0
	for click in state.clicks {
		if click.timestamp_ms >= start_ms && click.timestamp_ms <= end_ms {
			count += 1
		}
	}
	return count
}

find_session_index :: proc(state: ^App_State, id: i64) -> int {
	for session, index in state.sessions {
		if session.id == id {
			return index
		}
	}
	return -1
}

delete_selected_session :: proc(state: ^App_State, ui: ^UI_State) -> bool {
	index := find_session_index(state, ui.selected_session_id)
	if index < 0 {
		return false
	}
	ordered_remove(&state.sessions, index)
	ui.selected_session_id = -1
	return true
}

prune_old_records :: proc(state: ^App_State, current_ms: i64) {
	cutoff := current_ms - YEAR
	for i := len(state.sessions)-1; i >= 0; i -= 1 {
		if state.sessions[i].end_ms < cutoff {
			ordered_remove(&state.sessions, i)
		}
	}
	for i := len(state.clicks)-1; i >= 0; i -= 1 {
		if state.clicks[i].timestamp_ms < cutoff {
			ordered_remove(&state.clicks, i)
		}
	}
}

save_state :: proc(path: string, state: ^App_State) -> bool {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	fmt.sbprintfln(&builder, "TIMER_STATE|1")
	fmt.sbprintfln(
		&builder,
		"timer|%d|%d|%d|%d|%d",
		state.running ? 1 : 0,
		state.accumulated_ms,
		state.run_started_ms,
		state.recent_cleared_until_ms,
		state.next_session_id,
	)
	for session in state.sessions {
		fmt.sbprintfln(&builder, "session|%d|%d|%d", session.id, session.start_ms, session.end_ms)
	}
	for click in state.clicks {
		fmt.sbprintfln(
			&builder,
			"click|%d|%d|%d|%d",
			click.timestamp_ms,
			click.x,
			click.y,
			int(click.target),
		)
	}
	return os.write_entire_file(path, builder.buf[:])
}

next_field :: proc(line: ^string) -> (string, bool) {
	return strings.split_iterator(line, "|")
}

parse_i64 :: proc(value: string) -> (i64, bool) {
	return strconv.parse_i64(value)
}

load_state :: proc(path: string, state: ^App_State, current_ms: i64) -> bool {
	data, ok := os.read_entire_file(path, context.temp_allocator)
	if !ok || len(data) == 0 {
		return false
	}

	text := string(data)
	for raw_line in strings.split_lines_iterator(&text) {
		line := raw_line
		kind, has_kind := next_field(&line)
		if !has_kind {
			continue
		}
		switch kind {
		case "timer":
			running_text, ok0 := next_field(&line)
			accumulated_text, ok1 := next_field(&line)
			started_text, ok2 := next_field(&line)
			cleared_text, ok3 := next_field(&line)
			next_id_text, ok4 := next_field(&line)
			if !(ok0 && ok1 && ok2 && ok3 && ok4) {
				continue
			}
			running, parsed0 := parse_i64(running_text)
			accumulated, parsed1 := parse_i64(accumulated_text)
			started, parsed2 := parse_i64(started_text)
			cleared, parsed3 := parse_i64(cleared_text)
			next_id, parsed4 := parse_i64(next_id_text)
			if parsed0 && parsed1 && parsed2 && parsed3 && parsed4 {
				state.running = running != 0
				state.accumulated_ms = max(i64(0), accumulated)
				state.run_started_ms = started
				state.recent_cleared_until_ms = cleared
				state.next_session_id = max(i64(1), next_id)
			}
		case "session":
			id_text, ok0 := next_field(&line)
			start_text, ok1 := next_field(&line)
			end_text, ok2 := next_field(&line)
			if !(ok0 && ok1 && ok2) {
				continue
			}
			id, parsed0 := parse_i64(id_text)
			start_ms, parsed1 := parse_i64(start_text)
			end_ms, parsed2 := parse_i64(end_text)
			if parsed0 && parsed1 && parsed2 && id > 0 && start_ms > 0 && end_ms >= start_ms {
				append(&state.sessions, Session{id, start_ms, end_ms})
				state.next_session_id = max(state.next_session_id, id+1)
			}
		case "click":
			time_text, ok0 := next_field(&line)
			x_text, ok1 := next_field(&line)
			y_text, ok2 := next_field(&line)
			target_text, ok3 := next_field(&line)
			if !(ok0 && ok1 && ok2 && ok3) {
				continue
			}
			timestamp, parsed0 := parse_i64(time_text)
			x, parsed1 := parse_i64(x_text)
			y, parsed2 := parse_i64(y_text)
			target, parsed3 := parse_i64(target_text)
			if parsed0 && parsed1 && parsed2 && parsed3 && timestamp > 0 && target >= 0 && target <= i64(len(Click_Target)-1) {
				append(&state.clicks, Click_Record{timestamp, i32(x), i32(y), Click_Target(target)})
			}
		}
	}

	if state.running && (state.run_started_ms <= 0 || state.run_started_ms > current_ms+MINUTE) {
		state.run_started_ms = current_ms
	}
	prune_old_records(state, current_ms)
	return true
}

range_button_rect :: proc(index: int) -> rl.Rectangle {
	return rl.Rectangle{8 + f32(index)*47, 28, 43, 16}
}

range_target :: proc(index: int) -> Click_Target {
	switch index {
	case 0: return .Range_14_Days
	case 1: return .Range_30_Days
	case 2: return .Range_90_Days
	case:   return .Range_365_Days
	}
}

max_session_duration :: proc(state: ^App_State, current_ms, range_start: i64) -> i64 {
	maximum := i64(1)
	for session in state.sessions {
		if session.end_ms >= range_start {
			maximum = max(maximum, session.end_ms-session.start_ms)
		}
	}
	if state.running && current_ms >= range_start {
		maximum = max(maximum, current_ms-state.run_started_ms)
	}
	return maximum
}

session_bar_rect :: proc(session: Session, range_start, current_ms, maximum: i64, range_days: int) -> rl.Rectangle {
	total_range := i64(range_days)*DAY
	x_fraction := f32(session.start_ms-range_start) / f32(total_range)
	x_fraction = math.clamp(x_fraction, 0, 1)
	bar_width := math.clamp(GRAPH_RECT.width/f32(range_days)*0.62, 2, 7)
	height_fraction := f32(session.end_ms-session.start_ms) / f32(maximum)
	bar_height := max(f32(2), height_fraction*(GRAPH_RECT.height-11))
	x := GRAPH_RECT.x + x_fraction*(GRAPH_RECT.width-bar_width)
	y := GRAPH_RECT.y + GRAPH_RECT.height - bar_height - 3
	return rl.Rectangle{x, y, bar_width, bar_height}
}

hovered_session_index :: proc(state: ^App_State, mouse: rl.Vector2, current_ms: i64, range_days: int) -> int {
	range_start := current_ms - i64(range_days)*DAY
	maximum := max_session_duration(state, current_ms, range_start)
	for i := len(state.sessions)-1; i >= 0; i -= 1 {
		session := state.sessions[i]
		if session.end_ms < range_start {
			continue
		}
		rect := session_bar_rect(session, range_start, current_ms, maximum, range_days)
		hit_rect := rect
		hit_rect.x -= 2
		hit_rect.width += 4
		if rl.CheckCollisionPointRec(mouse, hit_rect) {
			return i
		}
	}
	return -1
}

recent_indices :: proc(state: ^App_State, current_ms: i64) -> ([10]int, int) {
	indices: [10]int
	count := 0
	cutoff := max(current_ms-14*DAY, state.recent_cleared_until_ms)
	for i := len(state.sessions)-1; i >= 0 && count < 10; i -= 1 {
		if state.sessions[i].end_ms >= cutoff {
			indices[count] = i
			count += 1
		}
	}
	return indices, count
}

draw_navigation :: proc(active: Tab) {
	rl.DrawRectangleGradientV(0, 0, WINDOW_WIDTH, NAV_HEIGHT, NAV_BG, BG)
	home_active := active == .Home
	history_active := active == .History
	if home_active {
		rl.DrawRectangle(0, NAV_HEIGHT-2, 92, 2, ORANGE)
	}
	if history_active {
		rl.DrawRectangle(92, NAV_HEIGHT-2, 108, 2, ORANGE)
	}

	// A compact house icon.
	home_color := home_active ? TEXT : MUTED
	rl.DrawTriangle({13, 7}, {7, 13}, {19, 13}, home_color)
	rl.DrawRectangle(9, 12, 8, 7, home_color)
	rl.DrawText("HOME", 24, 8, 9, home_color)

	// Three tiny bars communicate history without needing an external icon asset.
	history_color := history_active ? TEXT : MUTED
	rl.DrawRectangle(105, 14, 3, 5, history_color)
	rl.DrawRectangle(110, 10, 3, 9, history_color)
	rl.DrawRectangle(115, 6, 3, 13, history_color)
	rl.DrawText("HISTORY", 123, 8, 9, history_color)
}

draw_recent_panel :: proc(state: ^App_State, ui: ^UI_State, mouse: rl.Vector2, current_ms: i64) {
	panel_rect := rl.Rectangle{6, 142, 188, 54}
	rl.DrawRectangleRounded(panel_rect, 0.12, 4, PANEL)
	rl.DrawRectangleRoundedLinesEx(panel_rect, 0.12, 4, 1, PANEL_LIGHT)

	indices, count := recent_indices(state, current_ms)
	max_scroll := max(0, count-3)
	ui.recent_scroll = math.clamp(ui.recent_scroll, 0, max_scroll)
	rl.DrawText(fmt.ctprintf("RECENT  %d/10", count), 11, 147, 8, MUTED)

	clear_color := count > 0 ? ORANGE : MUTED
	if rl.CheckCollisionPointRec(mouse, CLEAR_RECT) && count > 0 {
		clear_color = YELLOW
	}
	rl.DrawText("CLEAR", 160, 147, 8, clear_color)

	if count == 0 {
		draw_centered_text("No sessions in this view", 100, 169, 9, MUTED)
		return
	}

	for row in 0..<3 {
		list_index := ui.recent_scroll + row
		if list_index >= count {
			break
		}
		session := state.sessions[indices[list_index]]
		y := i32(159 + row*11)
		row_rect := rl.Rectangle{9, f32(y-1), 181, 10}
		if rl.CheckCollisionPointRec(mouse, row_rect) {
			rl.DrawRectangleRounded(row_rect, 0.25, 3, PANEL_LIGHT)
		}
		rl.DrawCircle(14, y+3, 2, ORANGE)
		rl.DrawText(format_short_date(session.start_ms), 20, y, 8, TEXT)
		rl.DrawText(format_short_duration(session.end_ms-session.start_ms), 63, y, 8, BLUE_LIGHT)
		rl.DrawText(format_clock(session.start_ms), 112, y, 8, MUTED)
	}

	if count > 3 {
		scroll_height := 30.0 * (3.0/f32(count))
		scroll_y := 159.0 + f32(ui.recent_scroll)/f32(max_scroll)*(30.0-scroll_height)
		rl.DrawRectangleRounded({190, scroll_y, 2, scroll_height}, 1, 2, ORANGE)
	}
}

draw_timer_button :: proc(
	state: ^App_State,
	ui: ^UI_State,
	button_texture: rl.Texture2D,
	shader: rl.Shader,
	pressed_location: i32,
	hovered_location: i32,
	mouse: rl.Vector2,
	current_ms: i64,
) {
	hovered := point_in_circle(mouse, BUTTON_CENTER, BUTTON_RADIUS)
	pressed := ui.button_armed && rl.IsMouseButtonDown(.LEFT)
	press_offset := pressed ? f32(3) : f32(0)
	center := BUTTON_CENTER + rl.Vector2{0, press_offset}

	shadow_radius := pressed ? BUTTON_RADIUS-1 : BUTTON_RADIUS+2
	shadow_y := pressed ? center.y+3 : center.y+7
	rl.DrawCircleGradient(i32(center.x), i32(shadow_y), shadow_radius, SHADOW, rl.Color{4, 10, 18, 0})

	pressed_value := pressed ? f32(1) : f32(0)
	hovered_value := hovered ? f32(1) : f32(0)
	rl.SetShaderValue(shader, pressed_location, &pressed_value, .FLOAT)
	rl.SetShaderValue(shader, hovered_location, &hovered_value, .FLOAT)

	dest := rl.Rectangle{
		center.x,
		center.y,
		BUTTON_TEXTURE_SIZE,
		BUTTON_TEXTURE_SIZE,
	}
	source := rl.Rectangle{0, 0, f32(button_texture.width), f32(button_texture.height)}
	rl.BeginShaderMode(shader)
	rl.DrawTexturePro(
		button_texture,
		source,
		dest,
		{BUTTON_TEXTURE_SIZE/2, BUTTON_TEXTURE_SIZE/2},
		0,
		rl.WHITE,
	)
	rl.EndShaderMode()

	if hovered {
		rl.DrawRing(center, BUTTON_RADIUS+1, BUTTON_RADIUS+3, 0, 360, 72, YELLOW)
	}

	icon_color := TEXT
	if state.running {
		rl.DrawRectangle(i32(center.x)-10, i32(center.y)-20, 7, 24, icon_color)
		rl.DrawRectangle(i32(center.x)+4, i32(center.y)-20, 7, 24, icon_color)
	} else {
		rl.DrawTriangle(
			{center.x-8, center.y-21},
			{center.x-8, center.y+5},
			{center.x+15, center.y-8},
			icon_color,
		)
	}

	status_text: cstring = state.running ? "RUNNING" : "READY"
	status_color := state.running ? ORANGE : MUTED
	draw_centered_text(status_text, center.x, i32(center.y)-39, 8, status_color)
	draw_centered_text(format_duration(elapsed_ms(state, current_ms)), center.x, i32(center.y)+17, 12, TEXT)
}

draw_home :: proc(
	state: ^App_State,
	ui: ^UI_State,
	button_texture: rl.Texture2D,
	shader: rl.Shader,
	pressed_location: i32,
	hovered_location: i32,
	mouse: rl.Vector2,
	current_ms: i64,
) {
	draw_timer_button(state, ui, button_texture, shader, pressed_location, hovered_location, mouse, current_ms)
	draw_recent_panel(state, ui, mouse, current_ms)
}

draw_history :: proc(state: ^App_State, ui: ^UI_State, mouse: rl.Vector2, current_ms: i64) {
	for label, index in RANGE_LABELS {
		rect := range_button_rect(index)
		active := ui.range_days == RANGE_DAYS[index]
		fill := active ? ORANGE : PANEL
		if rl.CheckCollisionPointRec(mouse, rect) && !active {
			fill = PANEL_LIGHT
		}
		rl.DrawRectangleRounded(rect, 0.35, 4, fill)
		text_color := active ? BG : TEXT
		draw_centered_text(label, rect.x+rect.width/2, i32(rect.y)+4, 8, text_color)
	}

	rl.DrawRectangleRounded(GRAPH_RECT, 0.06, 3, PANEL)
	for row in 1..=3 {
		y := GRAPH_RECT.y + f32(row)*GRAPH_RECT.height/4
		rl.DrawLineEx({GRAPH_RECT.x+2, y}, {GRAPH_RECT.x+GRAPH_RECT.width-2, y}, 1, rl.Color{55, 78, 94, 100})
	}

	range_start := current_ms - i64(ui.range_days)*DAY
	maximum := max_session_duration(state, current_ms, range_start)
	draw_centered_text(format_short_duration(maximum), GRAPH_RECT.x+31, i32(GRAPH_RECT.y)+3, 7, MUTED)
	rl.DrawText(format_short_date(range_start), i32(GRAPH_RECT.x)+3, i32(GRAPH_RECT.y+GRAPH_RECT.height)-10, 7, MUTED)
	end_label := format_short_date(current_ms)
	end_width := rl.MeasureText(end_label, 7)
	rl.DrawText(end_label, i32(GRAPH_RECT.x+GRAPH_RECT.width)-end_width-3, i32(GRAPH_RECT.y+GRAPH_RECT.height)-10, 7, MUTED)

	hovered_index := hovered_session_index(state, mouse, current_ms, ui.range_days)
	visible_count := 0
	for session, index in state.sessions {
		if session.end_ms < range_start {
			continue
		}
		visible_count += 1
		rect := session_bar_rect(session, range_start, current_ms, maximum, ui.range_days)
		rl.DrawRectangleRec({rect.x+1, rect.y+2, rect.width, rect.height}, SHADOW)
		color := ORANGE
		if index == hovered_index {
			color = YELLOW
		} else if session.id == ui.selected_session_id {
			color = BLUE_LIGHT
		}
		rl.DrawRectangleRounded(rect, 0.35, 4, color)
	}

	if state.running && current_ms >= range_start {
		active := Session{-1, state.run_started_ms, current_ms}
		rect := session_bar_rect(active, range_start, current_ms, maximum, ui.range_days)
		rl.DrawRectangleRounded(rect, 0.35, 4, BLUE_LIGHT)
		rl.DrawCircle(i32(rect.x+rect.width/2), i32(rect.y), 2, YELLOW)
	}

	if visible_count == 0 && !state.running {
		draw_centered_text("No sessions in this range", 100, 86, 9, MUTED)
	}

	info_index := hovered_index
	if info_index < 0 {
		info_index = find_session_index(state, ui.selected_session_id)
	}
	if info_index >= 0 {
		session := state.sessions[info_index]
		duration := session.end_ms-session.start_ms
		click_count := clicks_during(state, session.start_ms, session.end_ms)
		rl.DrawText(format_session_span(session.start_ms, session.end_ms), 9, 141, 7, TEXT)
		rl.DrawText(fmt.ctprintf("#%d  •  %s  •  %d clicks", session.id, format_short_duration(duration), click_count), 9, 153, 8, BLUE_LIGHT)
		if hovered_index >= 0 {
			rl.DrawText("Click bar to select", 9, 166, 8, MUTED)
		} else {
			rl.DrawText(fmt.ctprintf("Session #%d selected", session.id), 9, 166, 8, MUTED)
		}
		delete_color := rl.CheckCollisionPointRec(mouse, DELETE_RECT) ? YELLOW : DANGER
		rl.DrawRectangleRounded(DELETE_RECT, 0.3, 4, rl.Color{69, 37, 41, 255})
		draw_centered_text("DELETE", DELETE_RECT.x+DELETE_RECT.width/2, i32(DELETE_RECT.y)+4, 8, delete_color)
	} else {
		rl.DrawText(fmt.ctprintf("%d sessions shown", visible_count), 9, 143, 9, TEXT)
		rl.DrawText("Hover for stats • click to select", 9, 157, 8, MUTED)
		rl.DrawText("Wheel or buttons change range", 9, 171, 8, MUTED)
	}
}

target_at :: proc(state: ^App_State, ui: ^UI_State, mouse: rl.Vector2, current_ms: i64) -> Click_Target {
	if mouse.y < NAV_HEIGHT {
		return mouse.x < 92 ? .Home_Tab : .History_Tab
	}
	if ui.tab == .Home {
		if point_in_circle(mouse, BUTTON_CENTER, BUTTON_RADIUS+3) {
			return .Timer
		}
		if rl.CheckCollisionPointRec(mouse, CLEAR_RECT) {
			return .Recent_Clear
		}
		return .Background
	}
	for _, index in RANGE_DAYS {
		if rl.CheckCollisionPointRec(mouse, range_button_rect(index)) {
			return range_target(index)
		}
	}
	if rl.CheckCollisionPointRec(mouse, DELETE_RECT) && find_session_index(state, ui.selected_session_id) >= 0 {
		return .Delete_Session
	}
	if rl.CheckCollisionPointRec(mouse, GRAPH_RECT) {
		return .Graph
	}
	return .Background
}

handle_release :: proc(state: ^App_State, ui: ^UI_State, mouse: rl.Vector2, current_ms: i64) {
	target := target_at(state, ui, mouse, current_ms)
	record_click(state, mouse, target)

	switch target {
	case .Background:
		// The click is intentionally still recorded for the audit trail.
	case .Home_Tab:
		ui.tab = .Home
	case .History_Tab:
		ui.tab = .History
		ui.button_armed = false
	case .Timer:
		if ui.button_armed && point_in_circle(mouse, BUTTON_CENTER, BUTTON_RADIUS) {
			toggle_timer(state, current_ms)
		}
	case .Recent_Clear:
		indices, count := recent_indices(state, current_ms)
		_ = indices
		if count > 0 {
			state.recent_cleared_until_ms = current_ms
			ui.recent_scroll = 0
		}
	case .Range_14_Days:
		ui.range_days = 14
	case .Range_30_Days:
		ui.range_days = 30
	case .Range_90_Days:
		ui.range_days = 90
	case .Range_365_Days:
		ui.range_days = 365
	case .Graph:
		index := hovered_session_index(state, mouse, current_ms, ui.range_days)
		if index >= 0 {
			ui.selected_session_id = state.sessions[index].id
		}
	case .Delete_Session:
		_ = delete_selected_session(state, ui)
	}
	ui.button_armed = false
	prune_old_records(state, current_ms)
	if !save_state(STATE_PATH, state) {
		fmt.eprintln("Could not save timer state to ", STATE_PATH)
	}
}

handle_wheel :: proc(state: ^App_State, ui: ^UI_State, mouse: rl.Vector2) {
	wheel := rl.GetMouseWheelMove()
	if wheel == 0 {
		return
	}
	if ui.tab == .Home && mouse.y >= 142 {
		_, count := recent_indices(state, now_ms())
		max_scroll := max(0, count-3)
		ui.recent_scroll = math.clamp(ui.recent_scroll - int(wheel), 0, max_scroll)
		return
	}
	if ui.tab == .History {
		current_index := 0
		for days, index in RANGE_DAYS {
			if days == ui.range_days {
				current_index = index
				break
			}
		}
		if wheel < 0 {
			current_index = min(len(RANGE_DAYS)-1, current_index+1)
		} else {
			current_index = max(0, current_index-1)
		}
		ui.range_days = RANGE_DAYS[current_index]
	}
}

make_button_texture :: proc() -> rl.Texture2D {
	image := rl.GenImageColor(i32(BUTTON_TEXTURE_SIZE), i32(BUTTON_TEXTURE_SIZE), rl.BLANK)
	rl.ImageDrawCircle(&image, i32(BUTTON_TEXTURE_SIZE/2), i32(BUTTON_TEXTURE_SIZE/2), 50, rl.WHITE)
	texture := rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	rl.SetTextureFilter(texture, .BILINEAR)
	return texture
}

make_window_icon :: proc() -> rl.Image {
	icon := rl.GenImageColor(32, 32, BG)
	rl.ImageDrawCircle(&icon, 16, 16, 12, BLUE)
	rl.ImageDrawCircleLines(&icon, 16, 16, 12, ORANGE)
	rl.ImageDrawTriangle(&icon, {13, 10}, {13, 22}, {23, 16}, TEXT)
	return icon
}

main :: proc() {
	state := App_State{next_session_id = 1}
	defer delete(state.sessions)
	defer delete(state.clicks)
	current_ms := now_ms()
	_ = load_state(STATE_PATH, &state, current_ms)

	ui := UI_State{
		tab = .Home,
		range_days = 14,
		selected_session_id = -1,
	}

	rl.SetConfigFlags({.VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Focus Timer")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.SetExitKey(.KEY_NULL)

	icon := make_window_icon()
	rl.SetWindowIcon(icon)
	rl.UnloadImage(icon)

	button_texture := make_button_texture()
	defer rl.UnloadTexture(button_texture)
	button_shader := rl.LoadShaderFromMemory(nil, BUTTON_FRAGMENT_SHADER)
	defer rl.UnloadShader(button_shader)
	pressed_location := rl.GetShaderLocation(button_shader, "u_pressed")
	hovered_location := rl.GetShaderLocation(button_shader, "u_hovered")

	last_periodic_save := current_ms
	for !rl.WindowShouldClose() {
		current_ms = now_ms()
		mouse := rl.GetMousePosition()

		if rl.IsMouseButtonPressed(.LEFT) {
			ui.button_armed = ui.tab == .Home && point_in_circle(mouse, BUTTON_CENTER, BUTTON_RADIUS)
		}
		if rl.IsMouseButtonReleased(.LEFT) {
			handle_release(&state, &ui, mouse, current_ms)
		}
		handle_wheel(&state, &ui, mouse)

		// A periodic snapshot protects long-running sessions even before a normal close.
		if current_ms-last_periodic_save >= 10*SECOND {
			_ = save_state(STATE_PATH, &state)
			last_periodic_save = current_ms
		}

		rl.BeginDrawing()
		rl.ClearBackground(BG)
		draw_navigation(ui.tab)
		if ui.tab == .Home {
			draw_home(
				&state,
				&ui,
				button_texture,
				button_shader,
				pressed_location,
				hovered_location,
				mouse,
				current_ms,
			)
		} else {
			draw_history(&state, &ui, mouse, current_ms)
		}
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	prune_old_records(&state, now_ms())
	if !save_state(STATE_PATH, &state) {
		fmt.eprintln("Could not save timer state to ", STATE_PATH)
	}
}
