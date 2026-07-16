import Foundation

struct NavigationWrite {
    let data: Data
    let label: String
    let transportWrite: ((Data) -> Void)?
    let onWrite: (() -> Void)?
    let onDrop: (() -> Void)?
    let onWriteFailure: (() -> Void)?
    fileprivate let protectedFromEviction: Bool

    init(
        data: Data,
        label: String,
        transportWrite: ((Data) -> Void)? = nil,
        onWrite: (() -> Void)? = nil,
        onDrop: (() -> Void)? = nil,
        onWriteFailure: (() -> Void)? = nil,
        protectedFromEviction: Bool = false
    ) {
        self.data = data
        self.label = label
        self.transportWrite = transportWrite
        self.onWrite = onWrite
        self.onDrop = onDrop
        self.onWriteFailure = onWriteFailure
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

    mutating func removeAll() {
        pendingPriorityWrites.removeAll()
        pendingWrites.removeAll()
    }

    mutating func flush(
        canSend: () -> Bool,
        maxWrites: Int = .max,
        write: (NavigationWrite) -> Void
    ) {
        var writesRemaining = max(0, maxWrites)
        while writesRemaining > 0 && count > 0 && canSend() {
            if !pendingPriorityWrites.isEmpty {
                write(pendingPriorityWrites.removeFirst())
            } else {
                write(pendingWrites.removeFirst())
            }
            writesRemaining -= 1
        }
    }
}
