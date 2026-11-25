/*
android.provider.DocumentsContract and android.database.Cursor, called through JNI by hand.

vendor:android/java's generated bindings don't include the android.provider or android.database
packages, so these methods are written the way its generated wrappers are: find the class and method
once, then call.
*/
package a2itg2

import "base:intrinsics"
import "core:sys/android"
import java "vendor:android/java"

@(private = "file") documents_class: android.jclass

@(private = "file")
documents_method :: proc "contextless" (cache: ^android.jmethodID, name, signature: cstring) -> (env: ^android.JNIEnv, class: android.jclass, id: android.jmethodID, exception: ^java.Throwable) {
	env = android.jni_env()
	class = intrinsics.atomic_load_explicit(&documents_class, .Acquire)
	if class == nil {
		local := env->FindClass("android/provider/DocumentsContract")
		if local == nil {
			return env, nil, nil, take_exception(env)
		}
		class = env->NewGlobalRef(local)
		env->DeleteLocalRef(local)
		intrinsics.atomic_store_explicit(&documents_class, class, .Release)
	}
	id = intrinsics.atomic_load_explicit(cache, .Acquire)
	if id == nil {
		id = env->GetStaticMethodID(class, name, signature)
		if id == nil {
			return env, class, nil, take_exception(env)
		}
		intrinsics.atomic_store_explicit(cache, id, .Release)
	}
	return
}

documents_get_tree_document_id :: proc "contextless" (tree: ^java.Uri) -> (id: ^java.String, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, class, method := documents_method(&cache, "getTreeDocumentId", "(Landroid/net/Uri;)Ljava/lang/String;") or_return
	args := [?]android.jvalue{{l = tree}}
	return (^java.String)(env->CallStaticObjectMethodA(class, method, &args[0])), take_exception(env)
}

documents_build_document_uri_using_tree :: proc "contextless" (tree: ^java.Uri, document_id: ^java.String) -> (uri: ^java.Uri, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, class, method := documents_method(&cache, "buildDocumentUriUsingTree", "(Landroid/net/Uri;Ljava/lang/String;)Landroid/net/Uri;") or_return
	args := [?]android.jvalue{{l = tree}, {l = document_id}}
	return (^java.Uri)(env->CallStaticObjectMethodA(class, method, &args[0])), take_exception(env)
}

documents_get_document_id :: proc "contextless" (document: ^java.Uri) -> (id: ^java.String, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, class, method := documents_method(&cache, "getDocumentId", "(Landroid/net/Uri;)Ljava/lang/String;") or_return
	args := [?]android.jvalue{{l = document}}
	return (^java.String)(env->CallStaticObjectMethodA(class, method, &args[0])), take_exception(env)
}

// The MIME type that makes documents_create_document make a folder (DocumentsContract.Document.MIME_TYPE_DIR).
DOCUMENT_FOLDER_MIME :: "vnd.android.document/directory"

// Creates a file in `parent` (a document URI). Android adds " (1)" etc. if the name is taken.
documents_create_document :: proc "contextless" (resolver: ^java.ContentResolver, parent: ^java.Uri, mime_type, display_name: ^java.String) -> (uri: ^java.Uri, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, class, method := documents_method(&cache, "createDocument", "(Landroid/content/ContentResolver;Landroid/net/Uri;Ljava/lang/String;Ljava/lang/String;)Landroid/net/Uri;") or_return
	args := [?]android.jvalue{{l = resolver}, {l = parent}, {l = mime_type}, {l = display_name}}
	return (^java.Uri)(env->CallStaticObjectMethodA(class, method, &args[0])), take_exception(env)
}

@(private = "file")
take_exception :: proc "contextless" (env: ^android.JNIEnv) -> ^java.Throwable {
	return (^java.Throwable)(android.jni_take_exception(env))
}

// The URI listing `parent_id`'s children (query it with documents_query_children).
documents_build_child_documents_uri_using_tree :: proc "contextless" (tree: ^java.Uri, parent_id: ^java.String) -> (uri: ^java.Uri, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, class, method := documents_method(&cache, "buildChildDocumentsUriUsingTree", "(Landroid/net/Uri;Ljava/lang/String;)Landroid/net/Uri;") or_return
	args := [?]android.jvalue{{l = tree}, {l = parent_id}}
	return (^java.Uri)(env->CallStaticObjectMethodA(class, method, &args[0])), take_exception(env)
}

// android.database.Cursor, by hand too (not in the generated bindings either): just what walking a
// query's rows needs.
@(private = "file") cursor_class: android.jclass

@(private = "file")
cursor_method :: proc "contextless" (cache: ^android.jmethodID, name, signature: cstring) -> (env: ^android.JNIEnv, id: android.jmethodID, exception: ^java.Throwable) {
	env = android.jni_env()
	class := intrinsics.atomic_load_explicit(&cursor_class, .Acquire)
	if class == nil {
		local := env->FindClass("android/database/Cursor")
		if local == nil do return env, nil, take_exception(env)
		class = env->NewGlobalRef(local)
		env->DeleteLocalRef(local)
		intrinsics.atomic_store_explicit(&cursor_class, class, .Release)
	}
	id = intrinsics.atomic_load_explicit(cache, .Acquire)
	if id == nil {
		id = env->GetMethodID(class, name, signature)
		if id == nil do return env, nil, take_exception(env)
		intrinsics.atomic_store_explicit(cache, id, .Release)
	}
	return
}

cursor_move_to_next :: proc "contextless" (cursor: ^java.Cursor) -> (more: bool, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, method := cursor_method(&cache, "moveToNext", "()Z") or_return
	more = env->CallBooleanMethodA(cursor, method, nil) != 0
	return more, take_exception(env)
}

cursor_get_string :: proc "contextless" (cursor: ^java.Cursor, column: i32) -> (value: ^java.String, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, method := cursor_method(&cache, "getString", "(I)Ljava/lang/String;") or_return
	args := [?]android.jvalue{{i = column}}
	return (^java.String)(env->CallObjectMethodA(cursor, method, &args[0])), take_exception(env)
}

cursor_get_long :: proc "contextless" (cursor: ^java.Cursor, column: i32) -> (value: i64, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, method := cursor_method(&cache, "getLong", "(I)J") or_return
	args := [?]android.jvalue{{i = column}}
	return i64(env->CallLongMethodA(cursor, method, &args[0])), take_exception(env)
}

cursor_close :: proc "contextless" (cursor: ^java.Cursor) -> (exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, method := cursor_method(&cache, "close", "()V") or_return
	env->CallVoidMethodA(cursor, method, nil)
	return take_exception(env)
}

// Deletes a document; a folder goes with everything in it. False when the provider refused.
documents_delete_document :: proc "contextless" (resolver: ^java.ContentResolver, document: ^java.Uri) -> (deleted: bool, exception: ^java.Throwable) {
	@(static) cache: android.jmethodID
	env, class, method := documents_method(&cache, "deleteDocument", "(Landroid/content/ContentResolver;Landroid/net/Uri;)Z") or_return
	args := [?]android.jvalue{{l = resolver}, {l = document}}
	return env->CallStaticBooleanMethodA(class, method, &args[0]) != 0, take_exception(env)
}
