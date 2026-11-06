//
//  Credentials.swift
//  SwiftGit2
//
//  Created by Tom Booth on 29/02/2016.
//  Copyright © 2016 GitHub, Inc. All rights reserved.
//

import Clibgit2

private class Wrapper<T> {
	let value: T

	init(_ value: T) {
		self.value = value
	}
}

public enum Credentials {
	case `default`
	case sshAgent
	case plaintext(username: String, password: String)
	case sshMemory(username: String, publicKey: String, privateKey: String, passphrase: String)

	internal static func fromPointer(_ pointer: UnsafeMutableRawPointer) -> Credentials {
		return Unmanaged<Wrapper<Credentials>>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue().value
	}

	internal static func releasePointer(_ pointer: UnsafeMutableRawPointer) {
		Unmanaged<Wrapper<Credentials>>.fromOpaque(UnsafeRawPointer(pointer)).release()
	}

	internal func toPointer() -> UnsafeMutableRawPointer {
		return Unmanaged.passRetained(Wrapper(self)).toOpaque()
	}
}

// MARK: - CloneCallbackContext

/// Bundles credentials and an optional transfer-progress handler so both can
/// share the single `payload` pointer available in `git_remote_callbacks`.
///
/// The progress handler receives `(receivedObjects, totalObjects, receivedBytes)`
/// and is called on whichever thread libgit2 runs the transfer on.
/// Set `shouldAbort` to a closure that returns `true` to have the next
/// progress callback return `GIT_EUSER`, causing libgit2 to abort the operation.
final class CloneCallbackContext {
	let credentials: Credentials
	let onTransferProgress: ((Int, Int, Int64) -> Void)?
	let shouldAbort: (() -> Bool)?
	/// Refs the server refused during a push (ref name → server status message).
	var pushRejections: [String: String] = [:]

	init(_ credentials: Credentials,
		 onTransferProgress: ((Int, Int, Int64) -> Void)? = nil,
		 shouldAbort: (() -> Bool)? = nil) {
		self.credentials = credentials
		self.onTransferProgress = onTransferProgress
		self.shouldAbort = shouldAbort
	}

	func toPointer() -> UnsafeMutableRawPointer {
		Unmanaged.passRetained(self).toOpaque()
	}

	static func fromPointer(_ pointer: UnsafeMutableRawPointer) -> CloneCallbackContext {
		Unmanaged<CloneCallbackContext>.fromOpaque(pointer).takeUnretainedValue()
	}

	static func releasePointer(_ pointer: UnsafeMutableRawPointer) {
		Unmanaged<CloneCallbackContext>.fromOpaque(pointer).release()
	}
}

// MARK: - C callbacks

/// libgit2 credentials callback — extracts credentials from the `CloneCallbackContext` payload.
internal func credentialsCallback(
	cred: UnsafeMutablePointer<UnsafeMutablePointer<git_cred>?>?,
	url: UnsafePointer<CChar>?,
	username: UnsafePointer<CChar>?,
	_: UInt32,
	payload: UnsafeMutableRawPointer?) -> Int32 {

	let name = username.map(String.init(cString:))
	let context = CloneCallbackContext.fromPointer(payload!)
	// libgit2 asks again after every 401; a cancelled operation must stop
	// answering or an auth retry loop can't be interrupted.
	if context.shouldAbort?() == true { return GIT_EUSER.rawValue }
	let result: Int32

	switch context.credentials {
	case .default:
		result = git_cred_default_new(cred)
	case .sshAgent:
		result = git_cred_ssh_key_from_agent(cred, name!)
	case .plaintext(let username, let password):
		result = git_cred_userpass_plaintext_new(cred, username, password)
	case .sshMemory(let username, let publicKey, let privateKey, let passphrase):
		result = git_cred_ssh_key_memory_new(cred, username, publicKey, privateKey, passphrase)
	}

	return (result != GIT_OK.rawValue) ? -1 : 0
}

/// libgit2 transfer-progress callback — forwards stats to the handler stored in the payload context.
internal func transferProgressCallback(
	stats: UnsafePointer<git_indexer_progress>?,
	payload: UnsafeMutableRawPointer?) -> Int32 {

	guard let stats, let payload else { return 0 }
	let context = CloneCallbackContext.fromPointer(payload)
	if context.shouldAbort?() == true { return -1 }  // GIT_EUSER — tells libgit2 to abort
	guard let handler = context.onTransferProgress else { return 0 }
	let s = stats.pointee
	handler(Int(s.received_objects), Int(s.total_objects), Int64(s.received_bytes))
	return 0
}

/// libgit2 sideband-progress callback — fires for every progress line the server sends
/// ("Enumerating objects…", "Counting objects…"). It is the only callback libgit2 runs
/// between the ref advertisement and the first pack byte, so it is where an abort
/// requested during the server-side pack phase gets honored.
internal func sidebandProgressCallback(
	str: UnsafePointer<CChar>?,
	len: Int32,
	payload: UnsafeMutableRawPointer?) -> Int32 {

	guard let payload else { return 0 }
	let context = CloneCallbackContext.fromPointer(payload)
	return context.shouldAbort?() == true ? GIT_EUSER.rawValue : 0
}

/// libgit2 certificate-check callback — runs right after the TLS/SSH handshake, the
/// earliest point at which an abort can be honored. `GIT_PASSTHROUGH` keeps libgit2's
/// own validation in effect, so this never changes which certificates are accepted.
internal func certificateCheckCallback(
	cert: UnsafeMutablePointer<git_cert>?,
	valid: Int32,
	host: UnsafePointer<CChar>?,
	payload: UnsafeMutableRawPointer?) -> Int32 {

	guard let payload else { return GIT_PASSTHROUGH.rawValue }
	let context = CloneCallbackContext.fromPointer(payload)
	return context.shouldAbort?() == true ? GIT_EUSER.rawValue : GIT_PASSTHROUGH.rawValue
}

