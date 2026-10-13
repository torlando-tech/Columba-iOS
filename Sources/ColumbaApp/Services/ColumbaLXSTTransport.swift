import Foundation
import LXSTSwift

/// Canonical input for every outgoing call, whether selected from a chat or
/// directly from an lxst.telephony node.
struct TelephonyCallTarget: Sendable, Equatable {
    let destinationHash: Data
    let publicKeys: Data
}

/// The common voice transport lifecycle. CallManager uses this interface in
/// both hosting modes; NodeNetworkTransport communicates through RnsTelephony.
protocol ColumbaLXSTTransport: NetworkTransport {
    /// Install transport-side observers / destination registration. Called once
    /// after construction, before any call.
    func start() async
    /// Stage the canonical target before `Telephone.call` invokes the neutral
    /// `NetworkTransport` seam (lets the transport verify the destination and
    /// recall the identity before the link opens). `async` so it is a valid
    /// actor-isolated protocol witness (a synchronous requirement on an actor
    /// conformer is rejected by the strict-concurrency checker).
    func prepareOutboundCall(_ target: TelephonyCallTarget) async
    /// Fire the pre-identify incoming-call hook
    /// (`CallManager.prepareForIncomingCall`) when an inbound link establishes,
    /// ahead of the post-identify ringing trigger.
    func setIncomingCallStartedHandler(_ handler: @escaping @Sendable () async -> Void) async
}
