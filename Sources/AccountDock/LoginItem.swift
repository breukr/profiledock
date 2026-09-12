import AppKit
import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var error: String?
    private let service: any LoginItemService

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
        status = service.status
    }

    var enabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }
    var statusName: String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    func refresh() {
        let current = service.status
        if current != status { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                let current = service.status
                if current != .enabled && current != .requiresApproval { try service.register() }
            } else if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
        } catch { self.error = error.localizedDescription }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
