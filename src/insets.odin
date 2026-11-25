/*
How much of the window the phone's own bars cover: the status bar at the top, the navigation bar
(back, home, recent apps, or the gesture handle) at the bottom.

Since Android 15 apps draw under these bars, so the screen keeps clear of them itself. Asked of
Android (decor view -> root window insets -> system bars, API 30+) when the window appears or changes.
Before the window is laid out Android has no answer: then nothing is kept clear until it does.
*/
package a2itg2

import glue "core:sys/android/native_app_glue"
import java "vendor:android/java"

Bar_Insets :: struct {
	top, bottom: int, // pixels
}

read_bar_insets :: proc(app: ^glue.android_app) -> (insets: Bar_Insets, ok: bool) {
	inner :: proc(app: ^glue.android_app, insets: ^Bar_Insets) -> (found: bool, exception: ^java.Throwable) {
		window := java.Activity_getWindow((^java.Activity)(app.activity.clazz)) or_return
		if window == nil do return false, nil
		view := java.Window_getDecorView(window) or_return
		if view == nil do return false, nil
		root := java.View_getRootWindowInsets(view) or_return
		if root == nil do return false, nil // not laid out yet
		bars_type := java.WindowInsets_Type_systemBars() or_return
		bars := java.WindowInsets_getInsets(root, bars_type) or_return
		if bars == nil do return false, nil
		top := java.Insets_get_top(bars) or_return
		bottom := java.Insets_get_bottom(bars) or_return
		insets^ = {top = int(top), bottom = int(bottom)}
		return true, nil
	}
	if java.push_local_frame() != nil do return {}, false
	defer java.pop_local_frame_all()
	found, exception := inner(app, &insets)
	return insets, found && exception == nil
}
