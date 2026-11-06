//
//  Push.swift
//  SwiftGit2
//
//  Pushing to (and listing) a remote given only its URL, without adding a
//  named remote to the repository's config -- so no URL or credential is
//  ever written to disk.
//

import Foundation
import Clibgit2

/// A ref advertised by a remote.
public struct RemoteReference {
	public let name: String
	public let oid: OID
}

/// Outcome of a push: refs the server refused, with its reason (for example a
/// protected branch). An empty dictionary means every ref was accepted.
public struct PushResult {
	public let rejectedReferences: [String: String]
}

private func remoteCallbacks(context: CloneCallbackContext) -> git_remote_callbacks {
	var callbacks = git_remote_callbacks()
	git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
	callbacks.credentials = credentialsCallback
	callbacks.sideband_progress = sidebandProgressCallback
	callbacks.certificate_check = certificateCheckCallback
	callbacks.payload = context.toPointer()
	callbacks.push_update_reference = pushUpdateReferenceCallback
	callbacks.push_transfer_progress = pushTransferProgressCallback
	return callbacks
}

private func pushUpdateReferenceCallback(
	refname: UnsafePointer<CChar>?,
	status: UnsafePointer<CChar>?,
	payload: UnsafeMutableRawPointer?) -> Int32 {
	guard let refname, let status, let payload else { return 0 }
	let context = CloneCallbackContext.fromPointer(payload)
	context.pushRejections[String(cString: refname)] = String(cString: status)
	return 0
}

private func pushTransferProgressCallback(
	current: UInt32,
	total: UInt32,
	bytes: Int,
	payload: UnsafeMutableRawPointer?) -> Int32 {
	guard let payload else { return 0 }
	let context = CloneCallbackContext.fromPointer(payload)
	if context.shouldAbort?() == true { return -1 }
	context.onTransferProgress?(Int(current), Int(total), Int64(bytes))
	return 0
}

/// Builds a git_strarray over C copies of `strings` and passes it to `body`.
private func withStrarray<T>(_ strings: [String], _ body: (inout git_strarray) -> T) -> T {
	let cStrings = strings.map { strdup($0) }
	defer { cStrings.forEach { free($0) } }
	var pointers = cStrings.map { UnsafeMutablePointer<CChar>($0) }
	return pointers.withUnsafeMutableBufferPointer { buffer in
		var array = git_strarray(strings: buffer.baseAddress, count: buffer.count)
		return body(&array)
	}
}

extension Repository {

	/// Lists the refs `url` advertises for pushing (heads, tags, and anything
	/// else the server exposes). Uses an anonymous remote: nothing is written
	/// to this repository's config. `shouldAbort` is polled from libgit2's
	/// callbacks so a cancelled caller doesn't wait out the connection.
	public func remoteReferences(url: String, credentials: Credentials,
	                             shouldAbort: (() -> Bool)? = nil) -> Result<[RemoteReference], NSError> {
		var remote: OpaquePointer?
		var rc = git_remote_create_anonymous(&remote, pointer, url)
		guard rc == GIT_OK.rawValue, let remote else {
			return .failure(NSError(gitError: rc, pointOfFailure: "git_remote_create_anonymous"))
		}
		defer { git_remote_free(remote) }

		let context = CloneCallbackContext(credentials, shouldAbort: shouldAbort)
		var callbacks = remoteCallbacks(context: context)
		defer { CloneCallbackContext.releasePointer(callbacks.payload) }

		if shouldAbort?() == true {
			return .failure(NSError(gitError: GIT_EUSER.rawValue, pointOfFailure: "git_remote_connect"))
		}
		rc = git_remote_connect(remote, GIT_DIRECTION_PUSH, &callbacks, nil, nil)

		guard rc == GIT_OK.rawValue else {
			return .failure(NSError(gitError: rc, pointOfFailure: "git_remote_connect"))
		}
		defer { git_remote_disconnect(remote) }

		var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
		var count = 0
		rc = withUnsafeMutablePointer(to: &heads) { headsPointer in
			headsPointer.withMemoryRebound(to: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?.self, capacity: 1) {
				git_remote_ls($0, &count, remote)
			}
		}
		guard rc == GIT_OK.rawValue else {
			return .failure(NSError(gitError: rc, pointOfFailure: "git_remote_ls"))
		}

		var references: [RemoteReference] = []
		for i in 0..<count {
			guard let head = heads?[i]?.pointee, let name = head.name else { continue }
			references.append(RemoteReference(name: String(cString: name), oid: OID(head.oid)))
		}
		return .success(references)
	}

	/// Pushes `refspecs` (e.g. `+refs/heads/*:refs/heads/*`, or `:refs/heads/old`
	/// to delete) to `url`. A transport or authentication failure returns an
	/// error; refs the server refuses individually are reported in the result.
	public func push(
		to url: String,
		refspecs: [String],
		credentials: Credentials,
		onTransferProgress: ((Int, Int, Int64) -> Void)? = nil,
		shouldAbort: (() -> Bool)? = nil
	) -> Result<PushResult, NSError> {
		var remote: OpaquePointer?
		var rc = git_remote_create_anonymous(&remote, pointer, url)
		guard rc == GIT_OK.rawValue, let remote else {
			return .failure(NSError(gitError: rc, pointOfFailure: "git_remote_create_anonymous"))
		}
		defer { git_remote_free(remote) }

		let context = CloneCallbackContext(credentials, onTransferProgress: onTransferProgress, shouldAbort: shouldAbort)
		var options = git_push_options()
		git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
		options.callbacks = remoteCallbacks(context: context)
		defer { CloneCallbackContext.releasePointer(options.callbacks.payload) }

		rc = withStrarray(refspecs) { array in
			git_remote_push(remote, &array, &options)
		}
		guard rc == GIT_OK.rawValue else {
			return .failure(NSError(gitError: rc, pointOfFailure: "git_remote_push"))
		}
		return .success(PushResult(rejectedReferences: context.pushRejections))
	}
}
