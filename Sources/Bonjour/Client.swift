//
//  Client.swift
//  NetService
//
//  Created by Alsey Coleman Miller on 11/5/18.
//  Copyright © 2018 PureSwift. All rights reserved.
//

import Foundation
#if canImport(NetService)
import NetService
#endif

#if os(macOS) || os(iOS) || canImport(NetService)
/// A network service browser that finds published services on a network using multicast DNS.
public final class NetServiceManager: NetServiceManagerProtocol {
    
    // MARK: - Properties
    
    public var log: ((String) -> ())?
    
    private let browser: NetServiceBrowser
    
    private var storage = Storage()
    
    private lazy var delegate = Delegate(self)
        
    /// All discovered services.
    public var services: Set<Service> {
        get async {
            return await Set(storage.state.cache.services.keys)
        }
    }
    
    /// All discovered domains.
    public var domains: Set<NetServiceDomain> {
        get async {
            return await storage.state.cache.domains
        }
    }
    
    // MARK: - Initialization
    
    public init() {
        self.browser = NetServiceBrowser()
        self.browser.delegate = self.delegate
        #if !canImport(NetService)
        let runloop = RunLoop.main
        self.browser.schedule(in: runloop, forMode: .default)
         // run loop
        Task.detached { [weak self] in
            while self != nil {
                await MainActor.run {
                    runloop.run(until: Date() + 0.1)
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        #endif
    }
    
    // MARK: - Methods
    
    /// Starts a search for services of a particular type within a specific domain.
    public func discoverServices(
        of type: NetServiceType,
        in domain: NetServiceDomain
    ) -> AsyncNetServiceDiscovery {
        let priority = Task.currentPriority
        return AsyncNetServiceDiscovery(bufferSize: 100, onTermination: { [weak self] in
            self?.browser.stop()
        }, { continuation in
            Task(priority: priority) {
                await self.storage.update {
                    // cancel current task
                    $0.continuation?.cancel()
                    // remove previous results
                    $0.cache.services.removeAll(keepingCapacity: true)
                    $0.continuation = .discoverServices(continuation)
                }
                browser.searchForServices(ofType: type.rawValue, inDomain: domain.rawValue)
            }
        })
    }
    
    /// Initiates a search for domains visible to the host.
    public func discoverDomains() -> AsyncNetServiceDomainDiscovery {
        let priority = Task.currentPriority
        return AsyncNetServiceDomainDiscovery(bufferSize: 100, onTermination: { [weak self] in
            self?.browser.stop()
        }, { continuation in
            Task(priority: priority) {
                await self.storage.update {
                    // cancel current task
                    $0.continuation?.cancel()
                    // remove previous results
                    $0.cache.services.removeAll(keepingCapacity: true)
                    $0.continuation = .discoverDomains(continuation)
                }
                browser.searchForBrowsableDomains()
            }
        })
    }
    
    /// Fetch the TXT record data for the specified service.
    ///
    /// - Parameter service: The service for which cached TXT record will be fetched.
    public func txtRecord(for service: Service) async -> TXTRecord? {
        return await storage.state.cache
            .services[service]?
            .txtRecordData()
            .flatMap { TXTRecord(data: $0) }
    }
    
    /// Resolve the address of the specified net service.
    public func resolve(_ service: Service, timeout: TimeInterval = 1.0) async throws -> Set<NetServiceAddress> {
        guard let netService = await self.storage.state.cache.services[service]
            else { throw NetServiceError.invalidService(service) }
        if let addresses = netService.addresses, addresses.isEmpty == false {
            return Set(addresses.lazy.map { NetServiceAddress(data: $0) })
        }
        let priority = Task.currentPriority
        return try await withCheckedThrowingContinuation { continuation in
            Task(priority: priority) {
                await self.storage.update {
                    // cancel current task
                    $0.continuation?.cancel()
                    $0.continuation = .resolve(continuation)
                }
                // perform action
                netService.resolve(withTimeout: timeout)
            }
        }
    }
    
    /// A string containing the DNS hostname for the specified service.
    ///
    /// - Parameter service: The service for which cached host name will be looked up.
    ///
    /// - Note: This value is `nil` until the service has been resolved (when addresses is `non-nil`).
    public func hostName(for service: Service) async -> String? {
        return await storage.state
            .cache
            .services[service]?
            .hostName
    }
}

internal extension NetServiceManager {
    
    final class Delegate: NSObject {
        
        private unowned var client: NetServiceManager
        
        fileprivate init(_ client: NetServiceManager) {
            self.client = client
        }
    }
}

// MARK: - NetServiceBrowserDelegate

extension NetServiceManager.Delegate: NetServiceBrowserDelegate {
    
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        client.log?("Will search")
    }
    
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        client.log?("Did stop search")
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        client.log?("Did not search: \(errorDict)")
        Task {
            await client.storage.update {
                guard case let .discoverDomains(continuation) = $0.continuation else {
                    return
                }
                continuation.finish(throwing: NetServiceError.errorDictionary(errorDict))
                $0.continuation = nil
            }
        }
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFindDomain domain: String, moreComing: Bool) {
        client.log?("Did find domain \(domain)" + (moreComing ? " (more coming)" : ""))
        // store values
        let domain = NetServiceDomain(rawValue: domain)
        Task {
            await client.storage.update {
                // cache value
                $0.cache.domains.insert(domain)
                // get current operation
                guard case let .discoverDomains(continuation) = $0.continuation else {
                    return
                }
                // yield value
                continuation.yield(domain)
            }
        }
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        client.log?("Did find service \(service.type) (\(service.name)) in \(service.domain)" + (moreComing ? " (more coming)" : ""))
        // convert to value
        let value = Service(service)
        // set delegate
        service.delegate = self
        // store values
        Task {
            await client.storage.update {
                // cache value
                $0.cache.services[value] = service
                // get current operation
                guard case let .discoverServices(continuation) = $0.continuation else {
                    return
                }
                // yield value
                continuation.yield(value)
            }
        }
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemoveDomain domain: String, moreComing: Bool) {
        client.log?("Did remove domain \(domain)" + (moreComing ? " (more coming)" : ""))
        Task {
            await client.storage.update {
                $0.cache.domains.remove(.init(rawValue: domain))
            }
        }
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        client.log?("Did remove service \(service.type) (\(service.name)) in \(service.domain)" + (moreComing ? " (more coming)" : ""))
        let value = Service(service)
        Task {
            await client.storage.update {
                $0.cache.services[value] = service
            }
        }
    }
}

// MARK: - NetServiceDelegate

extension NetServiceManager.Delegate: NetServiceDelegate {
    
    public func netServiceWillResolve(_ service: NetService) {
        client.log?("[\(service.domain)\(service.type)\(service.name)]: Will resolve")
    }
    
    public func netServiceDidResolveAddress(_ service: NetService) {
        client.log?("[\(service.domain)\(service.type)\(service.name)]: Did resolve")
        Task {
            await client.storage.update {
                // get current operation
                guard case let .resolve(continuation) = $0.continuation else {
                    return
                }
                // yield value
                let addresses = Set((service.addresses ?? []).lazy.map { NetServiceAddress(data: $0) })
                continuation.resume(returning: addresses)
                $0.continuation = nil
            }
        }
    }
    
    public func netService(_ service: NetService, didNotResolve errorDict: [String : NSNumber]) {
        client.log?("[\(service.domain)\(service.type)\(service.name)]: Did not resolve \(errorDict)")
        Task {
            await client.storage.update {
                // get current operation
                guard case let .resolve(continuation) = $0.continuation else {
                    return
                }
                // throw error
                continuation.resume(throwing: NetServiceError.errorDictionary(errorDict))
                $0.continuation = nil
            }
        }
    }
}

internal extension Service {
    
    init(_ service: NetService) {
        self.init(
            domain: NetServiceDomain(rawValue: service.domain),
            type: NetServiceType(rawValue: service.type),
            name: service.name
        )
    }
}

// MARK: - Supporting Types

internal extension NetServiceManager {
    
    enum Continuation {
        case discoverServices(AsyncIndefiniteStream<Service>.Continuation)
        case discoverDomains(AsyncIndefiniteStream<NetServiceDomain>.Continuation)
        case resolve(CheckedContinuation<Set<NetServiceAddress>, Error>)
    }
}

internal extension NetServiceManager.Continuation {
    
    func cancel() {
        switch self {
        case let .discoverServices(continuation):
            continuation.finish(throwing: CancellationError())
        case let .discoverDomains(continuation):
            continuation.finish(throwing: CancellationError())
        case let .resolve(continuation):
            continuation.resume(throwing: CancellationError())
        }
    }
}

internal extension NetServiceManager {
    
    actor Storage {
        
        var state = State()
        
        func update<T>(_ block: (inout State) throws -> (T)) rethrows -> T {
            try block(&self.state)
        }
    }
}

internal extension NetServiceManager {
    
    struct Cache {
        
        var services = [Service: NetService]()
        
        var domains = Set<NetServiceDomain>()
    }
}

internal extension NetServiceManager {
    
    struct State {
        
        var cache = Cache()
        
        var continuation: Continuation?
    }
}

#endif
