/*
Folder access through Android's folder picker (the Storage Access Framework).

	open_folder_picker     shows Android's picker; the answer comes back on Android's UI thread
	take_picker_result     hands that answer to the app's own loop
	keep_folder_access     asks Android to remember the access across restarts
	folder_access_kept     checks a remembered folder is still accessible
	write_file_in_folder   creates a file in the folder and writes bytes to it

A folder is identified by its "address": the picker's content:// URI as text.
The calls that can fail return "" on success, or a short error to show on screen.
*/
package a2itg2

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:sys/android"
import "core:sys/posix"
import glue "core:sys/android/native_app_glue"
import java "vendor:android/java"

// Tags the picker's answer among other activity results. Any number the app doesn't use elsewhere.
PICK_FOLDER_REQUEST :: 4201

Picker_Result :: struct {
	chosen:  bool,
	address: string, // heap allocated; the receiver deletes it
}

// The answer, written on the UI thread and read by the app's loop once `picker_ready` is set.
@(private = "file") picker_answer: Picker_Result
@(private = "file") picker_ready:  bool

open_folder_picker :: proc(app: ^glue.android_app) -> string {
	inner :: proc(app: ^glue.android_app) -> (exception: ^java.Throwable) {
		runnable_class := java.find_class("java/lang/Runnable") or_return
		runnable := java.proxy_new({runnable_class}, start_picker_on_ui_thread, app.activity.clazz) or_return
		// Activities must be driven from their UI thread.
		return java.Activity_runOnUiThread(activity(app), (^java.Runnable)(runnable))
	}
	local_frame_scope()
	return as_message(inner(app))
}

// Runs on Android's UI thread. `data` is the activity.
@(private = "file")
start_picker_on_ui_thread :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	action := java.string_from(java.Intent_ACTION_OPEN_DOCUMENT_TREE) or_return
	intent := java.Intent_new_String(action) or_return
	java.Intent_addFlags(intent, {
		.GRANT_READ_URI_PERMISSION,
		.GRANT_WRITE_URI_PERMISSION,
		.GRANT_PERSISTABLE_URI_PERMISSION,
		.GRANT_PREFIX_URI_PERMISSION,
	}) or_return
	exception = java.Activity_startActivityForResult_Intent_int((^java.Activity)(data), intent, PICK_FOLDER_REQUEST)
	return
}

// Adds the listener that receives activity results. Call again after APP_CMD_ACTIVITY_CHANGED.
listen_for_picker_result :: proc(app: ^glue.android_app) {
	if state.listener_set || app.activity == nil {
		return
	}
	listener, exception := java.odin_activity_add_listener(activity(app), on_activity_event)
	if exception != nil {
		say(.Bad, "COULD NOT LISTEN FOR THE PICKER:", describe(exception))
		return
	}
	java.delete_local(listener) // the activity holds on to it
	state.listener_set = true
}

// Runs on Android's UI thread for every activity result, permission result and new intent.
@(private = "file")
on_activity_event :: proc(data: rawptr, method: ^java.Method, args: ^java.Array(java.Object)) -> (result: ^java.Object, exception: ^java.Throwable) {
	if java.method_name(method) != "onActivityResult" {
		return
	}
	request_code := java.Integer_intValue((^java.Integer)(java.array_get(args, 0) or_return)) or_return
	if request_code != PICK_FOLDER_REQUEST {
		return
	}
	result_code := java.Integer_intValue((^java.Integer)(java.array_get(args, 1) or_return)) or_return
	intent := (^java.Intent)(java.array_get(args, 2) or_return)

	answer := Picker_Result{}
	if result_code == java.Activity_RESULT_OK && intent != nil {
		if uri := java.Intent_getData(intent) or_return; uri != nil {
			text := java.Uri_toString(uri) or_return
			answer.address = java.string_to(text, context.allocator) or_return
			answer.chosen = true
		}
	}
	picker_answer = answer
	intrinsics.atomic_store_explicit(&picker_ready, true, .Release)
	android.ALooper_wake(glue.app().looper)
	return
}

take_picker_result :: proc() -> (result: Picker_Result, ok: bool) {
	if !intrinsics.atomic_load_explicit(&picker_ready, .Acquire) {
		return
	}
	result = picker_answer
	picker_answer = {}
	intrinsics.atomic_store_explicit(&picker_ready, false, .Release)
	return result, true
}

keep_folder_access :: proc(address: string) -> string {
	inner :: proc(address: string) -> (exception: ^java.Throwable) {
		uri := parse_uri(address) or_return
		resolver := content_resolver() or_return
		return java.ContentResolver_takePersistableUriPermission(resolver, uri, {.GRANT_READ_URI_PERMISSION, .GRANT_WRITE_URI_PERMISSION})
	}
	local_frame_scope()
	return as_message(inner(address))
}

folder_access_kept :: proc(address: string) -> bool {
	inner :: proc(address: string) -> (kept: bool, exception: ^java.Throwable) {
		resolver := content_resolver() or_return
		list := java.ContentResolver_getPersistedUriPermissions(resolver) or_return
		count := java.List_size(list) or_return
		for i in 0..<count {
			permission := (^java.UriPermission)(java.List_get(list, i) or_return)
			uri := java.UriPermission_getUri(permission) or_return
			text := java.Uri_toString(uri) or_return
			kept_address := java.string_to(text, context.temp_allocator) or_return
			can_write := java.UriPermission_isWritePermission(permission) or_return
			if kept_address == address && can_write {
				return true, nil
			}
		}
		return false, nil
	}
	local_frame_scope()
	kept, exception := inner(address)
	if exception != nil {
		say(.Bad, "COULD NOT READ THE KEPT FOLDERS:", describe(exception))
	}
	return kept
}

write_file_in_folder :: proc(address, name: string, bytes: []byte) -> string {
	// Returns the new file as an open file handle.
	create :: proc(address, name: string) -> (fd: i32, exception: ^java.Throwable) {
		tree := parse_uri(address) or_return
		resolver := content_resolver() or_return
		folder_id := documents_get_tree_document_id(tree) or_return
		folder := documents_build_document_uri_using_tree(tree, folder_id) or_return
		mime := java.string_from("text/plain") or_return
		file_name := java.string_from(name) or_return
		file := documents_create_document(resolver, folder, mime, file_name) or_return
		if file == nil {
			return -1, nil
		}
		write_mode := java.string_from("w") or_return
		descriptor := java.ContentResolver_openFileDescriptor_Uri_String(resolver, file, write_mode) or_return
		return java.ParcelFileDescriptor_detachFd(descriptor)
	}

	fd, exception := create_in_local_frame(address, name, create)
	if exception != nil {
		return describe(exception)
	}
	if fd < 0 {
		return "ANDROID REFUSED TO CREATE THE FILE"
	}

	// From here on it is an ordinary file handle.
	defer posix.close(posix.FD(fd))
	for written := 0; written < len(bytes); {
		remaining := bytes[written:]
		n := posix.write(posix.FD(fd), raw_data(remaining), uint(len(remaining)))
		if n <= 0 {
			return fmt.tprintf("WRITE STOPPED AFTER %d OF %d BYTES", written, len(bytes))
		}
		written += int(n)
	}
	return ""
}

// The Java part of a write gets its own frame, popped before the (possibly long) plain write.
@(private = "file")
create_in_local_frame :: proc(address, name: string, create: proc(address, name: string) -> (i32, ^java.Throwable)) -> (i32, ^java.Throwable) {
	local_frame_scope()
	return create(address, name)
}

// "" when there was no exception, otherwise its description.
@(private = "file")
as_message :: proc(exception: ^java.Throwable) -> string {
	if exception != nil {
		return describe(exception)
	}
	return ""
}

// The app's loop thread never returns to Java, so Java references it makes would pile up.
// Every Java-touching call from that thread runs between these two.
@(private = "file")
@(deferred_none = java.pop_local_frame_all)
local_frame_scope :: proc() -> bool {
	return java.push_local_frame() == nil
}

@(private = "file")
activity :: proc(app: ^glue.android_app) -> ^java.Activity {
	return (^java.Activity)(app.activity.clazz)
}

@(private = "file")
content_resolver :: proc() -> (^java.ContentResolver, ^java.Throwable) {
	return java.Context_getContentResolver((^java.Context)(glue.app().activity.clazz))
}

@(private = "file")
parse_uri :: proc(address: string) -> (uri: ^java.Uri, exception: ^java.Throwable) {
	text := java.string_from(address) or_return
	return java.Uri_parse(text)
}

// A Java exception as a short line for the screen; frees the exception.
describe :: proc(exception: ^java.Throwable) -> string {
	message := java.exception_message(exception, context.temp_allocator)
	java.delete_local(exception)
	return strings.to_upper(message, context.temp_allocator)
}
