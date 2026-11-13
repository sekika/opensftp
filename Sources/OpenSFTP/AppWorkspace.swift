import AppKit
import SwiftUI
import SFTPCore

struct RemoteCopyRequest {
    let sourceWindowID: UUID
    let source: RemoteEndpoint
    let destinationDirectory: RemoteEndpoint
    var sourceKind: RemoteEntry.Kind? = nil
}

struct RemoteDragSnapshot {
    let sourceWindowID: UUID
    let sources: [RemoteEndpoint]
    let kinds: [RemoteEntry.Kind]
}

/// App-owned relationships and scheduling; navigation and selection stay local
/// to each window. Active remote jobs retain their owning model until settled.
@MainActor
final class AppWorkspace: ObservableObject {
    static let shared = AppWorkspace()
    @Published var language = AppLanguage.systemDefault()
    private var models: [UUID: WeakModel] = [:]
    private var activeOwners: [UUID: AppModel] = [:]
    private var drags: [UUID: RemoteDragSnapshot] = [:]
    private var nextWindowNumber = 1
    let scheduler = OperationScheduler()

    func register(_ model: AppModel) {
        if model.windowNumber == 0 { model.windowNumber = nextWindowNumber; nextWindowNumber += 1 }
        models[model.windowID] = WeakModel(model)
        model.language = language
        synchronize(model)
    }
    func unregister(_ model: AppModel) {
        models.removeValue(forKey: model.windowID)
        drags = drags.filter { $0.value.sourceWindowID != model.windowID }
        model.cancelLinkInspection()
        model.preview.close()
        synchronize(model)
    }
    var openModels: [AppModel] { models.values.compactMap { $0.value } }
    func setLanguage(_ language: AppLanguage) {
        self.language = language
        for model in openModels { model.language = language }
    }
    func reloadHosts() { for model in openModels { model.reloadHosts() } }

    func synchronize(_ owner: AppModel) {
        let active = owner.jobs.contains { job in
            if case .remoteCopy = job.request { return job.state == .waiting || job.state == .running }
            return false
        }
        if active { activeOwners[owner.windowID] = owner } else { activeOwners.removeValue(forKey: owner.windowID) }
        var owners = Dictionary(uniqueKeysWithValues: openModels.map { ($0.windowID, $0) })
        for (id, model) in activeOwners { owners[id] = model }
        for source in openModels {
            source.outgoingJobs = owners.values.flatMap { destination in
                destination.jobs.compactMap { job -> JobRecord? in
                    guard case let .remoteCopy(request) = job.request,
                          request.sourceWindowID == source.windowID, destination !== source else { return nil }
                    var reference = job
                    reference.stdout = ""; reference.stderr = ""; reference.completion = nil
                    return reference
                }
            }.sorted { $0.created < $1.created }
        }
    }
    func owner(of jobID: UUID) -> AppModel? {
        (openModels + Array(activeOwners.values)).first { $0.jobs.contains { $0.id == jobID } }
    }
    func interruptOutgoing(from model: AppModel) {
        for job in model.outgoingJobs where job.state == .waiting || job.state == .running {
            owner(of: job.id)?.cancelJob(job.id)
        }
    }
    func refresh(host: String) {
        for model in openModels where model.host == host && model.connected { model.refreshAfterMutation() }
    }
    func beginDrag(from model: AppModel) -> UUID {
        let id = UUID()
        drags[id] = RemoteDragSnapshot(sourceWindowID: model.windowID,
            sources: model.selectedEntries.map { RemoteEndpoint(host: model.host, path: SFTPCommand.join(model.path, $0.name)) },
            kinds: model.selectedEntries.map(\.kind))
        return id
    }
    func drag(_ id: UUID, to destination: AppModel) -> RemoteDragSnapshot? {
        guard let snapshot = drags[id], snapshot.sourceWindowID != destination.windowID,
              models[snapshot.sourceWindowID]?.value != nil, destination.connected else { return nil }
        return snapshot
    }
    func consumeDrag(_ id: UUID, to destination: AppModel) -> Bool {
        guard let snapshot = drag(id, to: destination) else { return false }
        drags.removeValue(forKey: id)
        let directory = RemoteEndpoint(host: destination.host, path: destination.path)
        for (source, kind) in zip(snapshot.sources, snapshot.kinds) {
            destination.copyRemote(RemoteCopyRequest(sourceWindowID: snapshot.sourceWindowID,
                                                      source: source, destinationDirectory: directory, sourceKind: kind))
        }
        return true
    }
    func endDrag(_ id: UUID) { drags.removeValue(forKey: id) }
}

@MainActor
private final class WeakModel {
    weak var value: AppModel?
    init(_ model: AppModel) { value = model }
}

/// FIFO permit shared by all window queues. Cancellation removes a waiter
/// without acquiring the permit or blocking unrelated windows indefinitely.
@MainActor
final class OperationScheduler {
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if owner == nil { owner = id; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        }, onCancel: {
            Task { @MainActor in self.cancel(id) }
        })
    }
    func release(_ id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty { owner = nil }
        else {
            let (next, continuation) = waiters.removeFirst()
            owner = next
            continuation.resume()
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
