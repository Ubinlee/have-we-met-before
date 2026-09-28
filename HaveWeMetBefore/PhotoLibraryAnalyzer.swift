import Combine
import Foundation
import Photos

struct PhotoVisitRecord: Identifiable, Sendable {
    let id: String
    let capturedAt: Date
    let latitude: Double
    let longitude: Double
}

struct PhotoScanSummary: Sendable {
    let totalPhotos: Int
    let validRecords: [PhotoVisitRecord]
    let visitEvents: [VisitEvent]
    let excludedImportedCount: Int
    let missingLocationCount: Int
    let missingDateCount: Int
    let invalidCoordinateCount: Int
    let duplicateCount: Int

    static let empty = PhotoScanSummary(
        totalPhotos: 0,
        validRecords: [],
        visitEvents: [],
        excludedImportedCount: 0,
        missingLocationCount: 0,
        missingDateCount: 0,
        invalidCoordinateCount: 0,
        duplicateCount: 0
    )
}

@MainActor
final class PhotoLibraryAnalyzer: ObservableObject {
    enum ScanState: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var scanState: ScanState = .idle
    @Published private(set) var summary: PhotoScanSummary = .empty

    init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var canReadPhotos: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    func requestAccessAndScan() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status

        guard canReadPhotos else {
            scanState = .idle
            return
        }

        await scan()
    }

    func scan() async {
        guard canReadPhotos else { return }

        scanState = .scanning
        let result = await Task.detached(priority: .userInitiated) {
            PhotoLibraryScanner.scan()
        }.value

        summary = result
        scanState = .finished
    }
}

private enum PhotoLibraryScanner {
    static func scan() -> PhotoScanSummary {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var records: [PhotoVisitRecord] = []
        var excludedImportedCount = 0
        var missingLocationCount = 0
        var missingDateCount = 0
        var invalidCoordinateCount = 0
        var duplicateCount = 0
        var duplicateKeys = Set<String>()

        assets.enumerateObjects { asset, _, _ in
            guard let capturedAt = asset.creationDate else {
                missingDateCount += 1
                return
            }

            guard isLikelyOwnedCapture(asset, capturedAt: capturedAt) else {
                excludedImportedCount += 1
                return
            }

            guard let location = asset.location else {
                missingLocationCount += 1
                return
            }

            let latitude = location.coordinate.latitude
            let longitude = location.coordinate.longitude
            guard isValid(latitude: latitude, longitude: longitude) else {
                invalidCoordinateCount += 1
                return
            }

            let duplicateKey = makeDuplicateKey(
                capturedAt: capturedAt,
                latitude: latitude,
                longitude: longitude
            )
            guard duplicateKeys.insert(duplicateKey).inserted else {
                duplicateCount += 1
                return
            }

            records.append(
                PhotoVisitRecord(
                    id: asset.localIdentifier,
                    capturedAt: capturedAt,
                    latitude: latitude,
                    longitude: longitude
                )
            )
        }

        return PhotoScanSummary(
            totalPhotos: assets.count,
            validRecords: records,
            visitEvents: VisitEventBuilder.build(from: records),
            excludedImportedCount: excludedImportedCount,
            missingLocationCount: missingLocationCount,
            missingDateCount: missingDateCount,
            invalidCoordinateCount: invalidCoordinateCount,
            duplicateCount: duplicateCount
        )
    }

    private static func isLikelyOwnedCapture(
        _ asset: PHAsset,
        capturedAt: Date
    ) -> Bool {
        let source = asset.sourceType
        guard source.contains(.typeUserLibrary),
              !source.contains(.typeCloudShared),
              !source.contains(.typeiTunesSynced),
              !asset.mediaSubtypes.contains(.photoScreenshot) else {
            return false
        }

        // iOS 26 exposes when an asset entered the library separately from when
        // it was captured. Camera photos are added immediately; received or
        // imported originals usually retain an older capture date.
        if #available(iOS 26.0, *) {
            let additionDelay = asset.addedDate.timeIntervalSince(capturedAt)
            return additionDelay >= -5 && additionDelay <= 60
        }

        // Earlier iOS versions expose no public ownership signal for a photo in
        // the main library. Keep local-library camera candidates rather than
        // silently deleting legitimate historical records.
        return true
    }

    private static func isValid(latitude: Double, longitude: Double) -> Bool {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return false
        }
        return latitude != 0 || longitude != 0
    }

    private static func makeDuplicateKey(
        capturedAt: Date,
        latitude: Double,
        longitude: Double
    ) -> String {
        let second = Int(capturedAt.timeIntervalSince1970.rounded())
        let roundedLatitude = Int((latitude * 100_000).rounded())
        let roundedLongitude = Int((longitude * 100_000).rounded())
        return "\(second):\(roundedLatitude):\(roundedLongitude)"
    }
}
