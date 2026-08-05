import Darwin
import Foundation

final class VaultWatcher {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onChange)
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
