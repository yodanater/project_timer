package main

import "core:os"
import "core:testing"

@(test)
timer_accumulates_wall_clock_time_and_creates_a_session :: proc(t: ^testing.T) {
	state := App_State{next_session_id = 1}
	defer delete(state.sessions)
	defer delete(state.clicks)

	toggle_timer(&state, 10*SECOND)
	testing.expect(t, state.running)
	testing.expect_value(t, state.run_started_ms, 10*SECOND)
	testing.expect_value(t, elapsed_ms(&state, 15*SECOND), 5*SECOND)

	toggle_timer(&state, 18*SECOND)
	testing.expect(t, !state.running)
	testing.expect_value(t, state.accumulated_ms, 8*SECOND)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, state.sessions[0].start_ms, 10*SECOND)
	testing.expect_value(t, state.sessions[0].end_ms, 18*SECOND)
}

@(test)
running_state_round_trips_and_catches_up_while_closed :: proc(t: ^testing.T) {
	path := "timer_state_test.txt"
	defer os.remove(path)

	saved := App_State{
		running = true,
		accumulated_ms = 3*SECOND,
		run_started_ms = 20*SECOND,
		recent_cleared_until_ms = 7*SECOND,
		next_session_id = 8,
	}
	defer delete(saved.sessions)
	defer delete(saved.clicks)
	append(&saved.sessions, Session{7, 12*SECOND, 18*SECOND})
	append(&saved.clicks, Click_Record{21*SECOND, 100, 83, .Timer})

	testing.expect(t, save_state(path, &saved))

	loaded := App_State{next_session_id = 1}
	defer delete(loaded.sessions)
	defer delete(loaded.clicks)
	testing.expect(t, load_state(path, &loaded, 25*SECOND))
	testing.expect(t, loaded.running)
	testing.expect_value(t, elapsed_ms(&loaded, 25*SECOND), 8*SECOND)
	testing.expect_value(t, loaded.recent_cleared_until_ms, 7*SECOND)
	testing.expect_value(t, loaded.next_session_id, i64(8))
	testing.expect_value(t, len(loaded.sessions), 1)
	testing.expect_value(t, len(loaded.clicks), 1)
	testing.expect_value(t, loaded.clicks[0].timestamp_ms, 21*SECOND)
}

@(test)
selected_history_session_is_permanently_removed_from_state :: proc(t: ^testing.T) {
	state := App_State{next_session_id = 3}
	defer delete(state.sessions)
	defer delete(state.clicks)
	append(&state.sessions, Session{1, 1*SECOND, 2*SECOND})
	append(&state.sessions, Session{2, 3*SECOND, 5*SECOND})
	ui := UI_State{selected_session_id = 1}

	testing.expect(t, delete_selected_session(&state, &ui))
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, state.sessions[0].id, i64(2))
	testing.expect_value(t, ui.selected_session_id, i64(-1))
}

@(test)
history_and_clicks_are_retained_for_one_year :: proc(t: ^testing.T) {
	current := 2*YEAR
	state := App_State{next_session_id = 3}
	defer delete(state.sessions)
	defer delete(state.clicks)
	append(&state.sessions, Session{1, current-YEAR-DAY, current-YEAR-DAY+SECOND})
	append(&state.sessions, Session{2, current-DAY, current-DAY+SECOND})
	append(&state.clicks, Click_Record{current-YEAR-DAY, 1, 1, .Background})
	append(&state.clicks, Click_Record{current-DAY, 2, 2, .Graph})

	prune_old_records(&state, current)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, state.sessions[0].id, i64(2))
	testing.expect_value(t, len(state.clicks), 1)
	testing.expect_value(t, state.clicks[0].target, Click_Target.Graph)
}
