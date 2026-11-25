/*
Asking before doing something that can't be undone: Android's own dialog with a message, Cancel and one
action button (e.g. Delete). The app's loop gets the answer through take_confirm_answer.

	open_confirm(app, "Delete from the stick?", "Squaredance will be gone from the stick.", "Delete")
	if answer, ok := take_confirm_answer(); ok && answer { ... }

Only the action button says yes; Cancel, Back and tapping outside all say no. What the yes is for is
kept by the caller (one question at a time).
*/
package a2itg2

import "base:intrinsics"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"
import java "vendor:android/java"

@(private = "file")
Confirm_Request :: struct {
	title, message, action: string, // heap; the UI thread frees them
}
@(private = "file") confirm_request: Confirm_Request
@(private = "file") answer_yes:      bool
@(private = "file") answer_ready:    bool

open_confirm :: proc(app: ^glue.android_app, title, message, action: string) -> string {
	confirm_request = {title = strings.clone(title), message = strings.clone(message), action = strings.clone(action)}
	answer_yes = false
	inner :: proc(app: ^glue.android_app) -> (exception: ^java.Throwable) {
		runnable_class := java.find_class("java/lang/Runnable") or_return
		runnable := java.proxy_new({runnable_class}, build_confirm_on_ui_thread, app.activity.clazz) or_return
		return java.Activity_runOnUiThread((^java.Activity)(app.activity.clazz), (^java.Runnable)(runnable))
	}
	if java.push_local_frame() != nil do return "OUT OF JAVA MEMORY"
	defer java.pop_local_frame_all()
	if exception := inner(app); exception != nil do return describe(exception)
	return ""
}

// The answer once the dialog has closed: yes only from the action button.
take_confirm_answer :: proc() -> (yes: bool, ok: bool) {
	if !intrinsics.atomic_load_explicit(&answer_ready, .Acquire) do return
	yes = answer_yes
	intrinsics.atomic_store_explicit(&answer_ready, false, .Release)
	return yes, true
}

@(private = "file")
build_confirm_on_ui_thread :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	activity := (^java.Context)(data)
	request := confirm_request
	defer {
		delete(request.title)
		delete(request.message)
		delete(request.action)
	}
	click_class := java.find_class("android/content/DialogInterface$OnClickListener") or_return
	on_yes := java.proxy_new({click_class}, on_action_button) or_return
	dismiss_class := java.find_class("android/content/DialogInterface$OnDismissListener") or_return
	on_dismiss := java.proxy_new({dismiss_class}, on_closed) or_return

	builder := java.AlertDialog_Builder_new_Context(activity) or_return
	java.AlertDialog_Builder_setTitle_CharSequence(builder, (^java.CharSequence)(java.string_from(request.title) or_return)) or_return
	java.AlertDialog_Builder_setMessage_CharSequence(builder, (^java.CharSequence)(java.string_from(request.message) or_return)) or_return
	java.AlertDialog_Builder_setPositiveButton_CharSequence_DialogInterface_OnClickListener(builder, (^java.CharSequence)(java.string_from(request.action) or_return), (^java.DialogInterface_OnClickListener)(on_yes)) or_return
	java.AlertDialog_Builder_setNegativeButton_CharSequence_DialogInterface_OnClickListener(builder, (^java.CharSequence)(java.string_from("Cancel") or_return), nil) or_return
	java.AlertDialog_Builder_setOnDismissListener(builder, (^java.DialogInterface_OnDismissListener)(on_dismiss)) or_return
	dialog := java.AlertDialog_Builder_create(builder) or_return
	java.Dialog_show((^java.Dialog)(dialog)) or_return
	return
}

@(private = "file")
on_action_button :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	answer_yes = true // the dialog closes after this, and on_closed hands the answer over
	return
}

@(private = "file")
on_closed :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	intrinsics.atomic_store_explicit(&answer_ready, true, .Release)
	android.ALooper_wake(glue.app().looper)
	return
}
