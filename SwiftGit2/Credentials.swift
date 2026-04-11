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
		// Use takeUnretainedValue so the wrapper is NOT released here.
		// libgit2 may invoke the credentials callback multiple times (e.g. SSH
		// retry), and takeRetainedValue would consume the retain on the first
		// call, leaving a dangling pointer for subsequent calls.
		// The caller is responsible for balancing the passRetained (see releasePointer).
		return Unmanaged<Wrapper<Credentials>>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue().value
	}

	/// Releases the retain created by `toPointer()`.  Call this once after the
	/// libgit2 operation that consumed the payload pointer has returned.
	internal static func releasePointer(_ pointer: UnsafeMutableRawPointer) {
		Unmanaged<Wrapper<Credentials>>.fromOpaque(UnsafeRawPointer(pointer)).release()
	}

	internal func toPointer() -> UnsafeMutableRawPointer {
		return Unmanaged.passRetained(Wrapper(self)).toOpaque()
	}
}

/// Handle the request of credentials, passing through to a wrapped block after converting the arguments.
/// Converts the result to the correct error code required by libgit2 (0 = success, 1 = rejected setting creds,
/// -1 = error)
internal func credentialsCallback(
	cred: UnsafeMutablePointer<UnsafeMutablePointer<git_cred>?>?,
	url: UnsafePointer<CChar>?,
	username: UnsafePointer<CChar>?,
	_: UInt32,
	payload: UnsafeMutableRawPointer? ) -> Int32 {

	let result: Int32

	// Find username_from_url
	let name = username.map(String.init(cString:))

	switch Credentials.fromPointer(payload!) {
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
