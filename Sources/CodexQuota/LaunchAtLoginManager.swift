import Foundation
import ServiceManagement

/// Simplified states required by the settings page for macOS login-item control.
enum LaunchAtLoginState {
  /// The application is registered and approved to launch after login.
  case enabled

  /// The application is not currently registered as a login item.
  case disabled

  /// Registration exists but macOS requires explicit approval in System Settings.
  case requiresApproval

  /// The operating system cannot currently resolve the main application service.
  case unavailable
}

/// Wraps the native helper-free `SMAppService.mainApp` login-item API.
final class LaunchAtLoginManager {
  /// File manager used for the helper-free LaunchAgent fallback on local signatures.
  private let fileManager: FileManager

  /// Standard per-user LaunchAgent path used only when `SMAppService` is unavailable.
  private let launchAgentURL: URL

  /// Fixed installed application path launched by the per-user fallback.
  private let installedApplicationURL = URL(fileURLWithPath: "/Applications/Codex Quota.app")

  /// Creates a manager with deterministic per-user fallback paths.
  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    launchAgentURL = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent("com.local.CodexQuota.plist", isDirectory: false)
  }

  /// Current system state normalized for the settings user interface.
  var state: LaunchAtLoginState {
    switch SMAppService.mainApp.status {
    case .enabled:
      return .enabled
    case .notRegistered:
      return .disabled
    case .requiresApproval:
      return .requiresApproval
    case .notFound:
      guard fileManager.fileExists(atPath: installedApplicationURL.path) else {
        return .unavailable
      }
      return fileManager.fileExists(atPath: launchAgentURL.path) ? .enabled : .disabled
    @unknown default:
      return .unavailable
    }
  }

  /// Registers or unregisters the signed main application without installing a helper.
  func setEnabled(_ enabled: Bool) throws {
    if SMAppService.mainApp.status == .notFound {
      if enabled {
        try installLaunchAgent()
      } else {
        try removeLaunchAgent()
      }
      return
    }

    if enabled {
      guard SMAppService.mainApp.status != .enabled,
        SMAppService.mainApp.status != .requiresApproval
      else {
        return
      }
      try SMAppService.mainApp.register()
    } else {
      guard SMAppService.mainApp.status != .notRegistered else {
        return
      }
      try SMAppService.mainApp.unregister()
    }
  }

  /// Opens the system Login Items page when macOS reports that approval is required.
  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  /// Writes a structured, private per-user LaunchAgent for the next graphical login.
  private func installLaunchAgent() throws {
    guard fileManager.fileExists(atPath: installedApplicationURL.path) else {
      throw CodexQuotaError.transport("应用尚未安装")
    }
    let payload: [String: Any] = [
      "Label": "com.local.CodexQuota",
      "ProgramArguments": [
        "/usr/bin/open",
        installedApplicationURL.path,
      ],
      "RunAtLoad": true,
      "ProcessType": "Background",
      "LimitLoadToSessionType": "Aqua",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: payload,
      format: .xml,
      options: 0
    )
    try fileManager.createDirectory(
      at: launchAgentURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: launchAgentURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: launchAgentURL.path
    )
  }

  /// Removes only the launch configuration owned by this application.
  private func removeLaunchAgent() throws {
    guard fileManager.fileExists(atPath: launchAgentURL.path) else {
      return
    }
    try fileManager.removeItem(at: launchAgentURL)
  }
}
