import AppKit
import Foundation
import UniformTypeIdentifiers

class ShareController: NSViewController {
    private var didHandleRequest = false

    override var nibName: NSNib.Name? {
        return nil
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        if let context = self.extensionContext {
            processExtensionContext(context)
        }
    }

    override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
        processExtensionContext(context)
    }

    private func processExtensionContext(_ context: NSExtensionContext) {
        guard !didHandleRequest else { return }
        didHandleRequest = true

        guard let items = context.inputItems as? [NSExtensionItem], !items.isEmpty else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var collectedPaths: [String] = []
        let fileUrlType = UTType.fileURL.identifier

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(fileUrlType) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: fileUrlType, options: nil) { data, _ in
                        defer { group.leave() }
                        if let url = data as? URL, url.isFileURL {
                            lock.lock()
                            collectedPaths.append(url.path)
                            lock.unlock()
                        } else if let nsurl = data as? NSURL, let url = nsurl as URL?, url.isFileURL {
                            lock.lock()
                            collectedPaths.append(url.path)
                            lock.unlock()
                        } else if let rawData = data as? Data,
                                  let url = URL(dataRepresentation: rawData, relativeTo: nil),
                                  url.isFileURL {
                            lock.lock()
                            collectedPaths.append(url.path)
                            lock.unlock()
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !collectedPaths.isEmpty {
                var comps = URLComponents()
                comps.scheme = "bridge"
                comps.host = "send"
                comps.queryItems = collectedPaths.map { URLQueryItem(name: "path", value: $0) }
                if let url = comps.url {
                    NSWorkspace.shared.open(url)
                }
            }
            context.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
