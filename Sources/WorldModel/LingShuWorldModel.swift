import Foundation

/// WorldModel is the neutral state layer for LingShu's perception, task and device facts.
/// Runtime modules publish user input, task lifecycle, capability and verification events here
/// instead of directly coupling to each other.
enum LingShuWorldEntityKind: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case agent
    case device
    case service
    case application
    case document
    case task
    case environment
    case location
    case unknown
}

enum LingShuWorldEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case perception
    case userInput
    case task
    case capability
    case device
    case verification
    case permission
    case memory
    case system
}

enum LingShuWorldTaskPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case thinking
    case planning
    case executing
    case waiting
    case verifying
    case completed
    case failed
    case cancelled
}

struct LingShuWorldEntity: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: LingShuWorldEntityKind
    var name: String
    var attributes: [String: String]
    var confidence: Double
    var firstSeenAt: Date
    var lastSeenAt: Date

    init(
        id: String,
        kind: LingShuWorldEntityKind,
        name: String,
        attributes: [String: String] = [:],
        confidence: Double = 1,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.attributes = attributes
        self.confidence = max(0, min(1, confidence))
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

struct LingShuWorldEvent: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: LingShuWorldEventKind
    var source: String
    var summary: String
    var relatedEntityIDs: [String]
    var payload: [String: String]
    var confidence: Double
    var occurredAt: Date

    init(
        id: String = UUID().uuidString,
        kind: LingShuWorldEventKind,
        source: String,
        summary: String,
        relatedEntityIDs: [String] = [],
        payload: [String: String] = [:],
        confidence: Double = 1,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.summary = summary
        self.relatedEntityIDs = relatedEntityIDs
        self.payload = payload
        self.confidence = max(0, min(1, confidence))
        self.occurredAt = occurredAt
    }
}

struct LingShuWorldTaskState: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var phase: LingShuWorldTaskPhase
    var ownerAgentID: String?
    var relatedEntityIDs: [String]
    var updatedAt: Date

    init(
        id: String,
        title: String,
        phase: LingShuWorldTaskPhase = .idle,
        ownerAgentID: String? = nil,
        relatedEntityIDs: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.phase = phase
        self.ownerAgentID = ownerAgentID
        self.relatedEntityIDs = relatedEntityIDs
        self.updatedAt = updatedAt
    }
}

struct LingShuWorldModel: Codable, Sendable, Equatable {
    var entities: [LingShuWorldEntity]
    var events: [LingShuWorldEvent]
    var tasks: [LingShuWorldTaskState]
    var updatedAt: Date

    init(
        entities: [LingShuWorldEntity] = [],
        events: [LingShuWorldEvent] = [],
        tasks: [LingShuWorldTaskState] = [],
        updatedAt: Date = Date()
    ) {
        self.entities = entities
        self.events = events
        self.tasks = tasks
        self.updatedAt = updatedAt
    }

    mutating func upsertEntity(_ entity: LingShuWorldEntity) {
        if let index = entities.firstIndex(where: { $0.id == entity.id }) {
            let firstSeen = entities[index].firstSeenAt
            entities[index] = LingShuWorldEntity(
                id: entity.id,
                kind: entity.kind,
                name: entity.name,
                attributes: entity.attributes,
                confidence: entity.confidence,
                firstSeenAt: firstSeen,
                lastSeenAt: entity.lastSeenAt
            )
        } else {
            entities.append(entity)
        }
        updatedAt = max(updatedAt, entity.lastSeenAt)
    }

    mutating func recordEvent(_ event: LingShuWorldEvent, maxEvents: Int = 500) {
        events.append(event)
        if maxEvents <= 0 {
            events.removeAll()
        } else if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
        updatedAt = max(updatedAt, event.occurredAt)
    }

    mutating func upsertTask(_ task: LingShuWorldTaskState) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        updatedAt = max(updatedAt, task.updatedAt)
    }

    func entity(id: String) -> LingShuWorldEntity? {
        entities.first { $0.id == id }
    }

    func entities(kind: LingShuWorldEntityKind) -> [LingShuWorldEntity] {
        entities.filter { $0.kind == kind }
    }

    func activeTasks() -> [LingShuWorldTaskState] {
        tasks.filter { ![.idle, .completed, .failed, .cancelled].contains($0.phase) }
    }
}
