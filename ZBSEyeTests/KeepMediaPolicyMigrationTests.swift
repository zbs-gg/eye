import Foundation
import XCTest

final class KeepMediaPolicyMigrationTests: XCTestCase {
    private let gb: Int64 = 1_024 * 1_024 * 1_024

    func testFreshEmptyProfileDefaultsToFiveGBWithoutMigrationPrune() {
        let resolution = KeepMediaMigration.resolve(
            snapshot: .init(days: .missing, maxGB: .missing, onboardingCompleted: nil),
            inventory: .positivelyEmpty
        )

        XCTAssertEqual(resolution.policy, .fiveGB)
        XCTAssertTrue(resolution.automaticDeletionAdmitted)
        XCTAssertFalse(resolution.shouldRunRetention)
    }

    func testExistingFiveGBRoundTripsWithoutWritingDifferentPolicyOrPruning() {
        let snapshot = LegacyKeepMediaSnapshot(
            days: .integer(0),
            maxGB: .integer(5),
            onboardingCompleted: true
        )

        let resolution = KeepMediaMigration.resolve(
            snapshot: snapshot,
            inventory: .reconciled(capturedMediaBytes: 4 * gb)
        )

        XCTAssertEqual(resolution.policy, .fiveGB)
        XCTAssertFalse(resolution.automaticDeletionAdmitted)
        XCTAssertFalse(resolution.shouldWritePolicy)
        XCTAssertFalse(resolution.shouldRunRetention)
    }

    func testUnlimitedAndDaysOnlyPoliciesBecomeForever() {
        let unlimited = KeepMediaMigration.resolve(
            snapshot: .init(days: .integer(0), maxGB: .integer(0), onboardingCompleted: true),
            inventory: .reconciled(capturedMediaBytes: 3 * gb)
        )
        let daysOnly = KeepMediaMigration.resolve(
            snapshot: .init(days: .integer(30), maxGB: .missing, onboardingCompleted: true),
            inventory: .reconciled(capturedMediaBytes: 3 * gb)
        )

        XCTAssertEqual(unlimited.policy, .forever)
        XCTAssertEqual(daysOnly.policy, .forever)
        XCTAssertFalse(unlimited.automaticDeletionAdmitted)
        XCTAssertFalse(daysOnly.automaticDeletionAdmitted)
    }

    func testUnsupportedFiniteCapsNormalizeOnlyUpward() {
        XCTAssertEqual(resolveFinite(7, bytes: 1 * gb).policy, .tenGB)
        XCTAssertEqual(resolveFinite(21, bytes: 1 * gb).policy, .fiftyGB)
        XCTAssertEqual(resolveFinite(51, bytes: 1 * gb).policy, .forever)
        XCTAssertEqual(resolveFinite(100, bytes: 1 * gb).policy, .forever)
    }

    func testExistingMediaPromotesToTheSmallestNonDestructiveTierWithoutPruning() {
        let five = resolveFinite(5, bytes: 7 * gb)
        let ten = resolveFinite(10, bytes: 21 * gb)
        let fifty = resolveFinite(50, bytes: 51 * gb)

        XCTAssertEqual(five.policy, .tenGB)
        XCTAssertEqual(ten.policy, .fiftyGB)
        XCTAssertEqual(fifty.policy, .forever)
        XCTAssertFalse(five.automaticDeletionAdmitted)
        XCTAssertFalse(ten.automaticDeletionAdmitted)
        XCTAssertFalse(fifty.automaticDeletionAdmitted)
        XCTAssertFalse(five.shouldRunRetention)
    }

    func testExistingMediaAtAnExactTierBoundaryDoesNotPromote() {
        XCTAssertEqual(resolveFinite(5, bytes: 5 * gb).policy, .fiveGB)
        XCTAssertEqual(resolveFinite(10, bytes: 10 * gb).policy, .tenGB)
        XCTAssertEqual(resolveFinite(20, bytes: 20 * gb).policy, .twentyGB)
        XCTAssertEqual(resolveFinite(50, bytes: 50 * gb).policy, .fiftyGB)
    }

    func testMissingOrCorruptPopulatedProfileFailsClosed() {
        let populatedMissing = KeepMediaMigration.resolve(
            snapshot: .init(days: .missing, maxGB: .missing, onboardingCompleted: true),
            inventory: .reconciled(capturedMediaBytes: gb)
        )
        let corrupt = KeepMediaMigration.resolve(
            snapshot: .init(days: .invalid("not-an-integer"), maxGB: .integer(5), onboardingCompleted: true),
            inventory: .reconciled(capturedMediaBytes: gb)
        )

        XCTAssertEqual(populatedMissing.policy, .forever)
        XCTAssertEqual(corrupt.policy, .forever)
        XCTAssertFalse(populatedMissing.automaticDeletionAdmitted)
        XCTAssertFalse(corrupt.automaticDeletionAdmitted)
    }

    func testUnavailableOrUnreconciledInventoryKeepsRecognizedPolicyClosed() {
        let unavailable = KeepMediaMigration.resolve(
            snapshot: .init(days: .integer(0), maxGB: .integer(5), onboardingCompleted: true),
            inventory: .uncertain(.configuredRootUnavailable)
        )
        let staleBytes = KeepMediaMigration.resolve(
            snapshot: .init(days: .integer(0), maxGB: .integer(5), onboardingCompleted: true),
            inventory: .uncertain(.byteMetadataMismatch)
        )

        XCTAssertEqual(unavailable.policy, .fiveGB)
        XCTAssertEqual(staleBytes.policy, .fiveGB)
        XCTAssertFalse(unavailable.automaticDeletionAdmitted)
        XCTAssertFalse(staleBytes.automaticDeletionAdmitted)
    }

    func testReceiptRoundTripsRawLegacyEvidenceAndDecision() throws {
        let snapshot = LegacyKeepMediaSnapshot(
            days: .integer(0),
            maxGB: .integer(7),
            onboardingCompleted: true
        )
        let inventory = KeepMediaInventoryEvidence.reconciled(capturedMediaBytes: 4 * gb)
        let resolution = KeepMediaMigration.resolve(snapshot: snapshot, inventory: inventory)
        let receipt = KeepMediaMigrationReceipt(
            legacySnapshot: snapshot,
            inventory: inventory,
            resolution: resolution
        )

        let decoded = try JSONDecoder().decode(
            KeepMediaMigrationReceipt.self,
            from: JSONEncoder().encode(receipt)
        )

        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.version, KeepMediaMigrationReceipt.currentVersion)
        XCTAssertEqual(decoded.resolution.policy, .tenGB)
    }

    @MainActor
    func testStorePersistsReceiptBeforePublishingFreshPolicyAndNeverRequestsPrune() throws {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let store = StorageSettingsStore(defaults: defaults)

        let resolution = store.initializeKeepMediaPolicy(inventory: .positivelyEmpty)

        XCTAssertEqual(resolution.policy, .fiveGB)
        XCTAssertFalse(resolution.shouldRunRetention)
        XCTAssertEqual(store.keepMediaPolicy, .fiveGB)
        XCTAssertTrue(store.automaticDeletionAdmitted)
        XCTAssertNotNil(defaults.data(forKey: StorageSettingsStore.keepMediaReceiptKey))
        XCTAssertEqual(
            defaults.string(forKey: StorageSettingsStore.keepMediaPolicyKey),
            KeepMediaPolicy.fiveGB.rawValue
        )
    }

    @MainActor
    func testStoreExistingFiveGBIsStableAndReopensOnlyAfterRestartReconciliation() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        defaults.set(0, forKey: StorageSettingsStore.daysKey)
        defaults.set(5, forKey: StorageSettingsStore.gbKey)
        defaults.set(true, forKey: StorageSettingsStore.onboardingKey)

        let first = StorageSettingsStore(defaults: defaults)
        _ = first.initializeKeepMediaPolicy(
            inventory: .reconciled(capturedMediaBytes: 4 * gb)
        )
        let second = StorageSettingsStore(defaults: defaults)
        _ = second.initializeKeepMediaPolicy(
            inventory: .reconciled(capturedMediaBytes: 4 * gb)
        )

        XCTAssertEqual(first.keepMediaPolicy, .fiveGB)
        XCTAssertEqual(second.keepMediaPolicy, .fiveGB)
        XCTAssertFalse(first.automaticDeletionAdmitted)
        XCTAssertTrue(second.automaticDeletionAdmitted)
        XCTAssertEqual(defaults.integer(forKey: StorageSettingsStore.daysKey), 0)
        XCTAssertEqual(defaults.integer(forKey: StorageSettingsStore.gbKey), 5)
    }

    @MainActor
    func testStoreMissingLegacyPreferencesOnPopulatedProfileFailsClosed() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        defaults.set(true, forKey: StorageSettingsStore.onboardingKey)
        let store = StorageSettingsStore(defaults: defaults)

        _ = store.initializeKeepMediaPolicy(
            inventory: .reconciled(capturedMediaBytes: gb)
        )

        XCTAssertEqual(store.keepMediaPolicy, .forever)
        XCTAssertFalse(store.automaticDeletionAdmitted)
    }

    @MainActor
    func testStoreRestoresPolicyFromReceiptAfterInterruptedPolicyWrite() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let first = StorageSettingsStore(defaults: defaults)
        _ = first.initializeKeepMediaPolicy(inventory: .positivelyEmpty)
        defaults.removeObject(forKey: StorageSettingsStore.keepMediaPolicyKey)

        let restarted = StorageSettingsStore(defaults: defaults)
        _ = restarted.initializeKeepMediaPolicy(inventory: .positivelyEmpty)

        XCTAssertEqual(restarted.keepMediaPolicy, .fiveGB)
        XCTAssertEqual(
            defaults.string(forKey: StorageSettingsStore.keepMediaPolicyKey),
            KeepMediaPolicy.fiveGB.rawValue
        )
    }

    @MainActor
    func testFreshFiniteAdmissionSurvivesRestartAfterMediaAppears() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let first = StorageSettingsStore(defaults: defaults)
        _ = first.initializeKeepMediaPolicy(inventory: .positivelyEmpty)

        let restarted = StorageSettingsStore(defaults: defaults)
        XCTAssertEqual(restarted.keepMediaPolicy, .fiveGB)
        XCTAssertFalse(restarted.automaticDeletionAdmitted)
        XCTAssertEqual(restarted.automaticRetentionRecord.phase, .pendingFinite)

        _ = restarted.initializeKeepMediaPolicy(
            inventory: .reconciled(capturedMediaBytes: gb)
        )

        XCTAssertEqual(restarted.keepMediaPolicy, .fiveGB)
        XCTAssertTrue(restarted.automaticDeletionAdmitted)
        XCTAssertEqual(restarted.automaticRetentionRecord.phase, .finiteAdmitted)
    }

    @MainActor
    func testRestartReconciliationPromotesPersistedFiniteAdmissionBeforeReopening() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let first = StorageSettingsStore(defaults: defaults)
        _ = first.initializeKeepMediaPolicy(inventory: .positivelyEmpty)

        let restarted = StorageSettingsStore(defaults: defaults)
        let resolution = restarted.initializeKeepMediaPolicy(
            inventory: .reconciled(capturedMediaBytes: 7 * gb)
        )

        XCTAssertEqual(resolution.policy, .tenGB)
        XCTAssertEqual(restarted.keepMediaPolicy, .tenGB)
        XCTAssertTrue(restarted.automaticDeletionAdmitted)
        XCTAssertEqual(restarted.automaticRetentionRecord.phase, .finiteAdmitted)
    }

    @MainActor
    func testRestartWithUncertainInventoryFailsPersistedFiniteAdmissionClosed() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let first = StorageSettingsStore(defaults: defaults)
        _ = first.initializeKeepMediaPolicy(inventory: .positivelyEmpty)

        let restarted = StorageSettingsStore(defaults: defaults)
        let resolution = restarted.initializeKeepMediaPolicy(
            inventory: .uncertain(.configuredRootUnavailable)
        )

        XCTAssertEqual(resolution.policy, .forever)
        XCTAssertFalse(resolution.automaticDeletionAdmitted)
        XCTAssertEqual(restarted.keepMediaPolicy, .forever)
        XCTAssertFalse(restarted.automaticDeletionAdmitted)
        XCTAssertEqual(restarted.automaticRetentionRecord.phase, .closed)
    }

    private func resolveFinite(_ cap: Int, bytes: Int64) -> KeepMediaMigrationResolution {
        KeepMediaMigration.resolve(
            snapshot: .init(days: .integer(0), maxGB: .integer(cap), onboardingCompleted: true),
            inventory: .reconciled(capturedMediaBytes: bytes)
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "KeepMediaPolicyMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}
