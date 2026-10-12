import Foundation

/// In-process transport for the same command implementation the extension uses.
final class LocalNodeAdapter: @unchecked Sendable {
    private let selectedHost: @Sendable () -> NodeHostingMode
    private let prepare: @Sendable () -> Void
    private let activate: @Sendable () -> Void
    private let cleanup: @Sendable () -> Void
    private let dispatch: @Sendable (ProxyRequest) async -> ProxyResponse

    convenience init() {
        let observers = NodeHostObservers()
        self.init(
            selectedHost: { NodeHostingMode.current },
            prepare: {
                PythonNodeBridgeHook.wireToPython()
                PythonNodeBLECallbackInvoker.install()
            },
            activate: { observers.start() },
            cleanup: { observers.stop() },
            dispatch: { await NodeCommandDispatcher.dispatch($0, host: .foreground) }
        )
    }

    init(selectedHost: @escaping @Sendable () -> NodeHostingMode,
         prepare: @escaping @Sendable () -> Void,
         activate: @escaping @Sendable () -> Void = {},
         cleanup: @escaping @Sendable () -> Void,
         dispatch: @escaping @Sendable (ProxyRequest) async -> ProxyResponse) {
        self.selectedHost = selectedHost
        self.prepare = prepare
        self.activate = activate
        self.cleanup = cleanup
        self.dispatch = dispatch
    }

    func send(_ data: Data) async -> Data? {
        do {
            guard let request = try ProxyIPC.decodeRequest(data) else { return nil }
            if case .start = request {
                guard selectedHost() == .foreground else {
                    return ProxyIPC.encodeResponse(.error("foreground host is not selected"))
                }
                prepare()
            }
            // Keep blocking Python operations off the app's main actor. Separate
            // tasks also allow cancellation commands to interrupt a running sync.
            let response = await Task.detached { await self.dispatch(request) }.value
            if case .start = request, case .ok = response { activate() }
            if case .stop = request, case .ok = response { cleanup() }
            return ProxyIPC.encodeResponse(response)
        } catch {
            return ProxyIPC.encodeResponse(.error("malformed node request"))
        }
    }
}
