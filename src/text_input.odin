/*
Typing with Android's own keyboard: a small dialog with a real text field (swipe, autocorrect,
suggestions, paste, any language), through vendor:android/java. No Java of our own.

	open_text_input(app, title, current_text)   shows the dialog (and the keyboard)
	take_text_events()                          what happened since, for the app's loop

The field reports every change (pack names are searched as you type) and a submit, from the
keyboard's search key or the SEARCH button. Events are made on Android's UI thread and handed to
the app's loop, which they wake.
*/
package a2itg2

import "core:strings"
import "core:sync"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"
import java "vendor:android/java"

Text_Event_Kind :: enum u8 {
	Changed,   // the text is now `text`
	Submitted, // search for `text`
	Closed,    // the dialog went away
}

Text_Event :: struct {
	kind: Text_Event_Kind,
	text: string, // heap; the receiver deletes it
}

@(private = "file") events_lock: sync.Mutex
@(private = "file") events:      [dynamic]Text_Event

// UI-thread side: the dialog and its field while it is open (global references).
@(private = "file") open_dialog: ^java.Dialog
@(private = "file") open_field:  ^java.EditText

@(private = "file")
Open_Request :: struct {
	title: string,
	text:  string,
}
@(private = "file") request: Open_Request // read once by the UI thread

open_text_input :: proc(app: ^glue.android_app, title, text: string) -> string {
	request = {title = strings.clone(title), text = strings.clone(text)}
	inner :: proc(app: ^glue.android_app) -> (exception: ^java.Throwable) {
		runnable_class := java.find_class("java/lang/Runnable") or_return
		runnable := java.proxy_new({runnable_class}, build_dialog_on_ui_thread, app.activity.clazz) or_return
		return java.Activity_runOnUiThread((^java.Activity)(app.activity.clazz), (^java.Runnable)(runnable))
	}
	if java.push_local_frame() != nil do return "OUT OF JAVA MEMORY"
	defer java.pop_local_frame_all()
	if exception := inner(app); exception != nil do return describe(exception)
	return ""
}

take_text_events :: proc(allocator := context.allocator) -> []Text_Event {
	sync.mutex_lock(&events_lock)
	defer sync.mutex_unlock(&events_lock)
	taken := make([]Text_Event, len(events), allocator)
	copy(taken, events[:])
	clear(&events)
	return taken
}

@(private = "file")
post :: proc(kind: Text_Event_Kind, text := "") {
	sync.mutex_lock(&events_lock)
	append(&events, Text_Event{kind = kind, text = strings.clone(text)})
	sync.mutex_unlock(&events_lock)
	android.ALooper_wake(glue.app().looper)
}

// Runs on Android's UI thread. `data` is the activity.
@(private = "file")
build_dialog_on_ui_thread :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	activity := (^java.Context)(data)
	title, text := request.title, request.text
	defer {
		delete(title)
		delete(text)
	}

	field := java.EditText_new_Context(activity) or_return
	java.TextView_setSingleLine_bool(field, true) or_return
	java.TextView_setInputType(field, java.InputType_TYPE_CLASS_TEXT) or_return
	java.TextView_setImeOptions(field, {action = .SEARCH, no_extract_ui = true}) or_return
	java.TextView_setText_CharSequence(field, (^java.CharSequence)(java.string_from(text) or_return)) or_return
	java.EditText_setSelection_int(field, i32(len_utf16(text))) or_return // the cursor at the end
	java.TextView_setHint_CharSequence(field, (^java.CharSequence)(java.string_from("Type to search") or_return)) or_return

	watcher_class := java.find_class("android/text/TextWatcher") or_return
	watcher := java.proxy_new({watcher_class}, on_text_changed) or_return
	java.TextView_addTextChangedListener(field, (^java.TextWatcher)(watcher)) or_return

	action_class := java.find_class("android/widget/TextView$OnEditorActionListener") or_return
	on_action := java.proxy_new({action_class}, on_keyboard_search) or_return
	java.TextView_setOnEditorActionListener(field, (^java.TextView_OnEditorActionListener)(on_action)) or_return

	click_class := java.find_class("android/content/DialogInterface$OnClickListener") or_return
	on_search := java.proxy_new({click_class}, on_search_button) or_return
	dismiss_class := java.find_class("android/content/DialogInterface$OnDismissListener") or_return
	on_dismiss := java.proxy_new({dismiss_class}, on_dialog_closed) or_return

	builder := java.AlertDialog_Builder_new_Context(activity) or_return
	java.AlertDialog_Builder_setTitle_CharSequence(builder, (^java.CharSequence)(java.string_from(title) or_return)) or_return
	java.AlertDialog_Builder_setView_View(builder, (^java.View)(field)) or_return
	java.AlertDialog_Builder_setPositiveButton_CharSequence_DialogInterface_OnClickListener(builder, (^java.CharSequence)(java.string_from("Search") or_return), (^java.DialogInterface_OnClickListener)(on_search)) or_return
	java.AlertDialog_Builder_setNegativeButton_CharSequence_DialogInterface_OnClickListener(builder, (^java.CharSequence)(java.string_from("Close") or_return), nil) or_return
	java.AlertDialog_Builder_setOnDismissListener(builder, (^java.DialogInterface_OnDismissListener)(on_dismiss)) or_return
	dialog := java.AlertDialog_Builder_create(builder) or_return

	// The keyboard comes up with the dialog, without a second tap on the field.
	window := java.Dialog_getWindow((^java.Dialog)(dialog)) or_return
	java.Window_setSoftInputMode(window, {state = .ALWAYS_VISIBLE}) or_return
	java.Dialog_show((^java.Dialog)(dialog)) or_return
	java.View_requestFocus_void((^java.View)(field)) or_return

	open_dialog = java.new_global((^java.Dialog)(dialog))
	open_field = java.new_global(field)
	return
}

// The field's text as an Odin string (heap).
@(private = "file")
field_text :: proc() -> (text: string, exception: ^java.Throwable) {
	if open_field == nil do return "", nil
	chars := java.TextView_getText(open_field) or_return
	java_text := java.CharSequence_toString(chars) or_return
	return java.string_to(java_text, context.allocator)
}

// TextWatcher: beforeTextChanged, onTextChanged, afterTextChanged. Only the last is needed.
@(private = "file")
on_text_changed :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	if java.method_name(method) != "afterTextChanged" do return
	text := field_text() or_return
	defer delete(text)
	post(.Changed, text)
	return
}

// The keyboard's own search key. Returns true: handled.
@(private = "file")
on_keyboard_search :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	text := field_text() or_return
	defer delete(text)
	post(.Submitted, text)
	if open_dialog != nil do java.DialogInterface_dismiss((^java.DialogInterface)(open_dialog)) or_return
	return (^java.Object)(java.Boolean_valueOf_bool(true) or_return), nil
}

@(private = "file")
on_search_button :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	text := field_text() or_return
	defer delete(text)
	post(.Submitted, text)
	return
}

@(private = "file")
on_dialog_closed :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	if open_field != nil do java.delete_global(open_field)
	if open_dialog != nil do java.delete_global(open_dialog)
	open_field, open_dialog = nil, nil
	post(.Closed)
	return
}

// Java counts text in UTF-16 units; the cursor goes after the last one.
@(private = "file")
len_utf16 :: proc(text: string) -> int {
	count := 0
	for r in text do count += 2 if r > 0xFFFF else 1
	return count
}
