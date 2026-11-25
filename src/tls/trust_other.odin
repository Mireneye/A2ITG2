#+build !windows
// The system's trusted roots away from Windows.
//   Android: one PEM file per root, in the Conscrypt module (Android 14 and newer, updated through
//            Google Play) or in the system image (older Android). The first folder found wins.
//   Linux:   the distribution's PEM bundle (Claude's sandbox).
// A2ITG2 change: the Android folders (Weaving's copy has only the Linux bundle).
package tls

import "core:os"

ANDROID_ROOT_FOLDERS :: [?]string{
	"/apex/com.android.conscrypt/cacerts",
	"/system/etc/security/cacerts",
}

trust_anchors_add_os :: proc(anchors: ^Trust_Anchors) -> int {
	when ODIN_PLATFORM_SUBTARGET == .Android {
		for folder in ANDROID_ROOT_FOLDERS {
			if added := add_pem_folder(anchors, folder); added > 0 do return added
		}
		return 0
	} else {
		text, err := os.read_entire_file("/etc/ssl/certs/ca-certificates.crt", context.allocator)
		if err != nil do return 0
		defer delete(text)
		return trust_anchors_add_pem(anchors, string(text))
	}
}

@(private = "file")
add_pem_folder :: proc(anchors: ^Trust_Anchors, folder: string) -> (added: int) {
	files, err := os.read_all_directory_by_path(folder, context.allocator)
	if err != nil do return 0
	defer os.file_info_slice_delete(files, context.allocator)
	for file in files {
		if file.type != .Regular do continue
		text, read_err := os.read_entire_file(file.fullpath, context.allocator)
		if read_err != nil do continue
		added += trust_anchors_add_pem(anchors, string(text))
		delete(text)
	}
	return
}
