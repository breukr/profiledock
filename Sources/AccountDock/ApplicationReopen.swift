import AppKit
import Carbon

enum ApplicationReopen {
    static func event(processIdentifier: pid_t) -> NSAppleEventDescriptor {
        // Address the running process, not its bundle ID: profiles can share an app.
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    static func send(processIdentifier: pid_t) throws {
        // Like a Dock click, ask the app to restore its window. Activation alone
        // leaves minimized windows in the Dock. Do not wait on the app's UI thread.
        _ = try event(processIdentifier: processIdentifier).sendEvent(options: [.noReply], timeout: 1)
    }
}
