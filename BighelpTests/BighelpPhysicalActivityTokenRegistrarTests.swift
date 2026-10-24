import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpPhysicalActivityTokenRegistrarTests {
    @Test func delayedOlderAccountWriteCannotRegressRotatedToken() async throws {
        let registrar = BighelpPhysicalActivityTokenRegistrar()
        let accountStarted = Signal()
        let accountFinished = Signal()
        var currentToken = Data([1])
        var sent: [Data] = []
        let older = Task {
            accountStarted.signal()
            await accountFinished.wait()
            try await registrar.register(physicalID: "physical", currentToken: { currentToken },
                isCurrent: { true }, send: { id, token in
                    #expect(id == "physical")
                    sent.append(token)
                })
        }
        await accountStarted.wait()
        currentToken = Data([2])
        try await registrar.register(physicalID: "physical", currentToken: { currentToken },
            isCurrent: { true }, send: { _, token in sent.append(token) })
        accountFinished.signal()
        try await older.value
        #expect(sent == [Data([2]), Data([2])])
    }

    @Test func rotationDuringSendConvergesBeforeQueuedAliasWrites() async throws {
        let registrar = BighelpPhysicalActivityTokenRegistrar()
        let sendStarted = Signal()
        let finishSend = Signal()
        let queued = Signal()
        var token = Data([1])
        var sent: [String] = []
        let first = Task {
            try await registrar.register(physicalID: "physical", currentToken: { token },
                isCurrent: { true }, send: { _, value in
                    sent.append("first:\(value.first!)")
                    if value == Data([1]) {
                        sendStarted.signal()
                        await finishSend.wait()
                    }
                })
        }
        await sendStarted.wait()
        let second = Task {
            try await registrar.register(physicalID: "physical", currentToken: { token },
                isCurrent: { queued.signal(); return true },
                send: { _, value in sent.append("queued:\(value.first!)") })
        }
        await queued.wait()
        #expect(sent == ["first:1"])
        token = Data([2])
        finishSend.signal()
        try await first.value
        try await second.value
        #expect(sent == ["first:1", "first:2", "queued:2"])
    }

    @Test func retiredOwnerCannotSend() async {
        let registrar = BighelpPhysicalActivityTokenRegistrar()
        await #expect(throws: BighelpPhysicalActivityTokenRegistrar.RegistrationError.ownerChanged) {
            try await registrar.register(physicalID: "physical", currentToken: { Data([1]) },
                isCurrent: { false }, send: { _, _ in Issue.record("Retired owner sent a token") })
        }
    }

    @Test func ownerRetiredWhileQueuedCannotSend() async throws {
        let registrar = BighelpPhysicalActivityTokenRegistrar()
        let sendStarted = Signal()
        let finishSend = Signal()
        let queued = Signal()
        var ownerIsCurrent = true
        let first = Task {
            try await registrar.register(physicalID: "physical", currentToken: { Data([1]) },
                isCurrent: { true }, send: { _, _ in
                    sendStarted.signal()
                    await finishSend.wait()
                })
        }
        await sendStarted.wait()
        let second = Task {
            await #expect(throws: BighelpPhysicalActivityTokenRegistrar.RegistrationError.ownerChanged) {
                try await registrar.register(physicalID: "physical", currentToken: { Data([2]) },
                    isCurrent: { queued.signal(); return ownerIsCurrent },
                    send: { _, _ in Issue.record("Retired queued owner sent a token") })
            }
        }
        await queued.wait()
        ownerIsCurrent = false
        finishSend.signal()
        try await first.value
        await second.value
    }

    @Test func ownerRetiredDuringSendCannotPublishRotation() async {
        let registrar = BighelpPhysicalActivityTokenRegistrar()
        let sendStarted = Signal()
        let finishSend = Signal()
        var ownerIsCurrent = true
        var token = Data([1])
        var sent: [Data] = []
        let registration = Task {
            await #expect(throws: BighelpPhysicalActivityTokenRegistrar.RegistrationError.ownerChanged) {
                try await registrar.register(physicalID: "physical", currentToken: { token },
                    isCurrent: { ownerIsCurrent }, send: { _, value in
                        sent.append(value)
                        sendStarted.signal()
                        await finishSend.wait()
                    })
            }
        }
        await sendStarted.wait()
        ownerIsCurrent = false
        token = Data([2])
        finishSend.signal()
        await registration.value
        #expect(sent == [Data([1])])
    }

    @Test(arguments: [false, true])
    func missingTokenNeverUsesCapturedFallback(afterSend: Bool) async {
        let registrar = BighelpPhysicalActivityTokenRegistrar()
        var token: Data? = afterSend ? Data([1]) : nil
        var sent: [Data] = []
        await #expect(throws: BighelpPhysicalActivityTokenRegistrar.RegistrationError.tokenUnavailable) {
            try await registrar.register(physicalID: "physical", currentToken: { token },
                isCurrent: { true }, send: { _, value in
                    sent.append(value)
                    token = nil
                })
        }
        #expect(sent == (afterSend ? [Data([1])] : []))
    }

    @Test func failedSendDoesNotPoisonQueuedOrFutureRetries() async throws {
        let registrar = BighelpPhysicalActivityTokenRegistrar()
        let sendStarted = Signal()
        let finishSend = Signal()
        let queued = Signal()
        var sent: [Data] = []
        let failing = Task {
            await #expect(throws: SendFailure.offline) {
                try await registrar.register(physicalID: "physical", currentToken: { Data([1]) },
                    isCurrent: { true }, send: { _, value in
                        sent.append(value)
                        sendStarted.signal()
                        await finishSend.wait()
                        throw SendFailure.offline
                    })
            }
        }
        await sendStarted.wait()
        let retry = Task {
            try await registrar.register(physicalID: "physical", currentToken: { Data([1]) },
                isCurrent: { queued.signal(); return true }, send: { _, value in sent.append(value) })
        }
        await queued.wait()
        finishSend.signal()
        await failing.value
        try await retry.value
        try await registrar.register(physicalID: "physical", currentToken: { Data([3]) },
            isCurrent: { true }, send: { _, value in sent.append(value) })
        #expect(sent == [Data([1]), Data([1]), Data([3])])
    }

    @Test func differentPhysicalIDsDoNotBlockEachOther() async throws {
        let registrar = BighelpPhysicalActivityTokenRegistrar()
        let sendStarted = Signal()
        let finishSend = Signal()
        var sent: [String] = []
        let first = Task {
            try await registrar.register(physicalID: "first", currentToken: { Data([1]) },
                isCurrent: { true }, send: { id, _ in
                    sent.append(id)
                    sendStarted.signal()
                    await finishSend.wait()
                })
        }
        await sendStarted.wait()
        try await registrar.register(physicalID: "second", currentToken: { Data([2]) },
            isCurrent: { true }, send: { id, _ in sent.append(id) })
        #expect(sent == ["first", "second"])
        finishSend.signal()
        try await first.value
    }

    @Test func completedCallsReleaseOwnersAndRegistrar() async throws {
        weak var releasedRegistrar: BighelpPhysicalActivityTokenRegistrar?
        do {
            let registrar = BighelpPhysicalActivityTokenRegistrar()
            releasedRegistrar = registrar
            for index in 0..<32 {
                weak var releasedOwner: Owner?
                do {
                    let owner = Owner()
                    releasedOwner = owner
                    try await registrar.register(physicalID: "physical-\(index)",
                        currentToken: { owner.token }, isCurrent: { owner.isCurrent },
                        send: { _, value in #expect(value == owner.token) })
                }
                #expect(releasedOwner == nil)
            }
        }
        #expect(releasedRegistrar == nil)
    }

    private enum SendFailure: Error { case offline }

    @MainActor private final class Owner {
        let token = Data([1])
        let isCurrent = true
    }

    @MainActor private final class Signal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !signalled else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func signal() {
            signalled = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}
