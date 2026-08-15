# Focus Timer

A compact 200 × 200 desktop timer written in Odin with raylib. It uses a custom GLSL shader for the raised/pressed timer button and saves sessions plus timestamped click records locally.

## Build and run

```powershell
odin build . -out:focus_timer.exe
.\focus_timer.exe
```

If `odin` is not on `PATH`, invoke your Odin executable directly and keep the same `build . -out:focus_timer.exe` arguments.

## Controls

- Release the mouse over the large center button to start or pause. Pressing down only changes its appearance; the timer state changes on release.
- Use **Home** for the timer and the temporary recent-session list. The list contains up to the last 10 sessions from two weeks and supports mouse-wheel scrolling. **Clear** hides the current list without deleting history.
- Use **History** for the interactive session graph. Hover a bar for its start time, duration, and click count; click it to select it, then use **Delete** for permanent removal.
- Select **2W**, **1M**, **3M**, or **1Y**, or use the mouse wheel, to change the graph range.

## Persistence

`timer_state.txt` is written beside the working directory used to launch the app. It stores the active timer, accumulated time, one year of session history, and one year of timestamped click records. When the app closes during an active timer, reopening it includes all elapsed wall-clock time while it was closed.
