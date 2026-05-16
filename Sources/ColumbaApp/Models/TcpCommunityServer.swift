//
//  TcpCommunityServer.swift
//  ColumbaApp
//
//  Community TCP server directory matching Android Columba.
//  Provides a curated list of public Reticulum transport nodes.
//

import Foundation
import RNSAPI

/// A public Reticulum TCP transport node.
struct TcpCommunityServer: Identifiable {
    let id = UUID()
    let name: String
    let host: String
    let port: UInt16
    let isBootstrap: Bool

    /// Address string in "host:port" format.
    var address: String { "\(host):\(port)" }
}

// MARK: - Server Directory

extension TcpCommunityServer {
    /// Curated list of public Reticulum transport nodes.
    ///
    /// Sourced from Android Columba's `TcpCommunityServers.kt`.
    /// Bootstrap servers are preferred for first-time connections.
    static let servers: [TcpCommunityServer] = [
        // Bootstrap servers
        TcpCommunityServer(name: "Beleth RNS Hub", host: "rns.beleth.net", port: 4242, isBootstrap: true),
        TcpCommunityServer(name: "Quad4 RNS", host: "rns.quad4.io", port: 4242, isBootstrap: true),
        TcpCommunityServer(name: "FireZen Hub", host: "reticulum.firezen.xyz", port: 4242, isBootstrap: true),

        // Community servers
        TcpCommunityServer(name: "RNS Amsterdam", host: "amsterdam.connect.reticulum.network", port: 4965, isBootstrap: false),
        TcpCommunityServer(name: "RNS BetweenTheBorders", host: "betweentheborders.com", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "RNS Frankfurt", host: "frankfurt.connect.reticulum.network", port: 5377, isBootstrap: false),
        TcpCommunityServer(name: "i2p Reticulum", host: "uxg5a4t3pnif7zoo43fkdrhgamlbfcovgsrzjakqab3pxjfqwdcq.b32.i2p", port: 5001, isBootstrap: false),
        TcpCommunityServer(name: "Reticulum Ireland", host: "reticulum.liamcottle.net", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "TheHub", host: "thehub.duckdns.org", port: 4242, isBootstrap: false),
        TcpCommunityServer(name: "Kosciuszko", host: "kosciuszko.au.int.rns.directory", port: 9696, isBootstrap: false),
        TcpCommunityServer(name: "Reticulum Ireland v2", host: "reticulum.liamcottle.net", port: 4343, isBootstrap: false),
        TcpCommunityServer(name: "RNS Roaming", host: "roaming.int.rns.directory", port: 9697, isBootstrap: false),
    ]

    /// Default server for first-time connections.
    static var defaultServer: TcpCommunityServer {
        servers.first(where: { $0.isBootstrap }) ?? servers[0]
    }
}
