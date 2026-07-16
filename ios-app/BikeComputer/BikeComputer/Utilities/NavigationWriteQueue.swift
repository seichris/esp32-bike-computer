import Foundation

struct NavigationWrite {
    let data: Data
    let label: String
    let transportWrite: ((Data) -> Void)?
    let onWrite: (() -> Void)?
    let onDrop: (() -> Void)?
    fileprivate let protectedFromEviction: Bool

    init(
        data: Data,
        label: String,
        transportWrite: ((Data) -> Void)? = nil,
        onWrite: (() -> Void)? = nil,
        onDrop: (() -> Void)? = nil,
        protectedFromEviction: Bool = false
    ) {
        self.data = data
        self.label = label
        self.transportWrite = transportWrite
        self.onWrite = onWrite
        self.onDrop = onDrop
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
            protectedFromEviction: true
        )
    }
}

struct NavigationWriteQueue {
    let maxCount: Int
    private var pendingWrites: [NavigationWrite] = []

    var count: Int {
        pendingWrites.count
    }

    var remainingCapacity: Int {
        max(maxCount - pendingWrites.count, 0)
    }

    init(maxCount: Int) {
        self.maxCount = max(1, maxCount)
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

    mutating func removeAll() {
        pendingWrites.removeAll()
    }

    mutating func flush(
        canSend: () -> Bool,
        maxWrites: Int = .max,
        write: (NavigationWrite) -> Void
    ) {
        var writesRemaining = max(0, maxWrites)
        while writesRemaining > 0 && !pendingWrites.isEmpty && canSend() {
            write(pendingWrites.removeFirst())
            writesRemaining -= 1
        }
    }
}
