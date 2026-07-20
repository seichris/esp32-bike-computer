import Foundation

struct NavigationWrite {
    let data: Data
    let label: String
    let transportWrite: ((Data) -> Void)?
    let onWrite: (() -> Void)?
    let onDrop: (() -> Void)?
    let onWriteFailure: (() -> Void)?
    let transportCanSend: (() -> Bool)?
    let transportExpectsWriteResponse: Bool?
    fileprivate let coalescingKey: String?
    fileprivate let protectedFromEviction: Bool

    init(
        data: Data,
        label: String,
        transportWrite: ((Data) -> Void)? = nil,
        onWrite: (() -> Void)? = nil,
        onDrop: (() -> Void)? = nil,
        onWriteFailure: (() -> Void)? = nil,
        transportCanSend: (() -> Bool)? = nil,
        transportExpectsWriteResponse: Bool? = nil,
        coalescingKey: String? = nil,
        protectedFromEviction: Bool = false
    ) {
        self.data = data
        self.label = label
        self.transportWrite = transportWrite
        self.onWrite = onWrite
        self.onDrop = onDrop
        self.onWriteFailure = onWriteFailure
        self.transportCanSend = transportCanSend
        self.transportExpectsWriteResponse = transportExpectsWriteResponse
        self.coalescingKey = coalescingKey
        self.protectedFromEviction = protectedFromEviction
    }

    func perform(using fallbackWrite: (Data) -> Void) {
        if let transportWrite {
            transportWrite(data)
        } else {
            fallbackWrite(data)
        }
        onWrite?()
    }

    fileprivate func protectingAtomicBatch() -> NavigationWrite {
        NavigationWrite(
            data: data,
            label: label,
            transportWrite: transportWrite,
            onWrite: onWrite,
            onDrop: onDrop,
            onWriteFailure: onWriteFailure,
            transportCanSend: transportCanSend,
            transportExpectsWriteResponse: transportExpectsWriteResponse,
            coalescingKey: coalescingKey,
            protectedFromEviction: true
        )
    }
}

struct NavigationWriteQueue {
    let maxCount: Int
    let priorityMaxCount: Int
    private var pendingWrites: [NavigationWrite] = []
    private var pendingPriorityWrites: [NavigationWrite] = []

    var count: Int {
        pendingPriorityWrites.count + pendingWrites.count
    }

    var remainingCapacity: Int {
        max(maxCount - pendingWrites.count, 0)
    }

    init(maxCount: Int, priorityMaxCount: Int = 1) {
        self.maxCount = max(1, maxCount)
        self.priorityMaxCount = max(1, priorityMaxCount)
    }

    @discardableResult
    mutating func enqueue(_ write: NavigationWrite) -> Bool {
        pendingWrites.append(write)
        guard pendingWrites.count > maxCount else { return false }

        // Never split a logical message that was accepted atomically. If the
        // queue consists only of protected chunks, the newly appended regular
        // write is the eviction candidate.
        let droppedIndex = pendingWrites.firstIndex { !$0.protectedFromEviction }
            ?? pendingWrites.startIndex
        let droppedWrite = pendingWrites.remove(at: droppedIndex)
        droppedWrite.onDrop?()
        return true
    }

    /// Enqueues a logical multi-frame message without evicting older traffic
    /// or exposing only a prefix of the message to the transport.
    @discardableResult
    mutating func enqueueAtomically(_ writes: [NavigationWrite]) -> Bool {
        guard writes.count <= remainingCapacity else { return false }
        pendingWrites.append(contentsOf: writes.map { $0.protectingAtomicBatch() })
        return true
    }

    /// Inserts a small control response into a separate bounded lane ahead of
    /// bulk traffic. A newer complete response replaces the older priority
    /// message, without consuming or evicting regular/catalog capacity.
    @discardableResult
    mutating func enqueuePrioritizedAtomically(_ writes: [NavigationWrite]) -> Bool {
        guard !writes.isEmpty, writes.count <= priorityMaxCount else {
            return false
        }

        if pendingPriorityWrites.count + writes.count > priorityMaxCount {
            pendingPriorityWrites.forEach { $0.onDrop?() }
            pendingPriorityWrites.removeAll()
        }
        pendingPriorityWrites.append(contentsOf: writes.map {
            $0.protectingAtomicBatch()
        })
        return true
    }

    /// Replaces older pending writes for the same logical state without
    /// disturbing unrelated priority traffic. This keeps high-rate state
    /// relays from replaying obsolete values after a newer state transition.
    @discardableResult
    mutating func enqueueCoalescing(
        _ write: NavigationWrite,
        prioritized: Bool
    ) -> Bool {
        guard let key = write.coalescingKey, !key.isEmpty else {
            if prioritized {
                return enqueuePrioritizedAtomically([write])
            }
            _ = enqueue(write)
            return true
        }

        removePendingWrites(withCoalescingKey: key)
        if prioritized {
            guard pendingPriorityWrites.count < priorityMaxCount else {
                return false
            }
            pendingPriorityWrites.append(write.protectingAtomicBatch())
            return true
        }

        pendingWrites.append(write)
        guard pendingWrites.count > maxCount else { return true }
        let droppedIndex = pendingWrites.firstIndex { !$0.protectedFromEviction }
            ?? pendingWrites.startIndex
        let rejectedNewWrite = droppedIndex == pendingWrites.index(before: pendingWrites.endIndex)
        let droppedWrite = pendingWrites.remove(at: droppedIndex)
        if rejectedNewWrite {
            // The caller receives `false` and owns retry scheduling. Invoking
            // onDrop here would schedule a second immediate retry and can spin
            // while a protected atomic batch keeps the queue full.
            return false
        }
        droppedWrite.onDrop?()
        return true
    }

    mutating func removeAll() {
        pendingPriorityWrites.removeAll()
        pendingWrites.removeAll()
    }

    mutating func removePendingWrites(withCoalescingKey key: String) {
        let priorityMatches = pendingPriorityWrites.indices.reversed().filter {
            pendingPriorityWrites[$0].coalescingKey == key
        }
        for index in priorityMatches {
            pendingPriorityWrites.remove(at: index).onDrop?()
        }

        let regularMatches = pendingWrites.indices.reversed().filter {
            pendingWrites[$0].coalescingKey == key
        }
        for index in regularMatches {
            pendingWrites.remove(at: index).onDrop?()
        }
    }

    mutating func flush(
        canSend: () -> Bool,
        maxWrites: Int = .max,
        write: (NavigationWrite) -> Void
    ) {
        flush(
            canSend: { _ in canSend() },
            maxWrites: maxWrites,
            write: write
        )
    }

    mutating func flush(
        canSend: (NavigationWrite) -> Bool,
        maxWrites: Int = .max,
        write: (NavigationWrite) -> Void
    ) {
        var writesRemaining = max(0, maxWrites)
        while writesRemaining > 0 && count > 0 {
            let nextWrite = pendingPriorityWrites.first ?? pendingWrites.first!
            guard canSend(nextWrite) else { break }
            let dequeued = pendingPriorityWrites.isEmpty
                ? pendingWrites.removeFirst()
                : pendingPriorityWrites.removeFirst()
            write(dequeued)
            writesRemaining -= 1
        }
    }
}
