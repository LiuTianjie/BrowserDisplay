import Foundation

protocol VirtualDisplayProvider {
    var name: String { get }

    func availability() async -> VirtualDisplayAvailability
    func createDisplay(request: VirtualDisplayRequest) async throws -> VirtualDisplayRecord
    func removeDisplay(record: VirtualDisplayRecord) async throws
}
