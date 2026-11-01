import Foundation

/// Liste les modèles un par un. Un modèle Ollama est un manifeste plus ses blobs :
/// seuls les blobs qu'aucun autre modèle n'utilise peuvent partir avec lui.
struct LocalModelScanner {
    let env: ScanEnvironment

    func category(_ collector: inout Collector) -> ScanCategory {
        ScanCategory(
            id: "local-models", title: "Modèles IA locaux",
            summary: "Volumineux, mais retirer un modèle peut casser vos projets.",
            items: ollama(&collector) + lmStudio(&collector) + huggingFace(&collector)
        )
    }

    private struct OllamaManifest {
        let url: URL
        let name: String
        let blobs: Set<String>
    }

    private func ollama(_ collector: inout Collector) -> [ScanItem] {
        let root = env.home.appendingPathComponent(".ollama/models")
        let manifestsRoot = root.appendingPathComponent("manifests")
        guard FileSystem.entryExists(manifestsRoot) else { return [] }
        guard let walker = FileManager.default.enumerator(at: manifestsRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            collector.denied.insert(manifestsRoot.path)
            return []
        }
        var manifests: [OllamaManifest] = []
        for case let url as URL in walker where !FileSystem.isDirectory(url) {
            guard let blobs = Self.blobs(inManifest: url) else { continue }
            let parts = url.pathComponents.suffix(2)
            manifests.append(OllamaManifest(url: url, name: parts.joined(separator: ":"), blobs: blobs))
        }
        var usage: [String: Int] = [:]
        for manifest in manifests {
            for blob in manifest.blobs { usage[blob, default: 0] += 1 }
        }
        return manifests.map { manifest in
            let exclusive = manifest.blobs.filter { usage[$0] == 1 }.sorted()
                .map { root.appendingPathComponent("blobs/\($0)") }
                .filter(FileSystem.entryExists)
            let size = exclusive.reduce(FileSystem.allocatedSize(of: manifest.url)) { $0 + FileSystem.allocatedSize(of: $1) }
            let shared = manifest.blobs.count - exclusive.count
            return ScanItem(
                url: manifest.url, name: "Ollama · \(manifest.name)",
                detail: shared > 0 ? "\(shared) couche(s) partagée(s) conservée(s)" : "À retélécharger si besoin",
                size: size, companions: exclusive
            )
        }
    }

    static func blobs(inManifest url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = json["layers"] as? [[String: Any]] else { return nil }
        var digests = layers.compactMap { $0["digest"] as? String }
        if let config = json["config"] as? [String: Any], let digest = config["digest"] as? String {
            digests.append(digest)
        }
        return Set(digests.map { $0.replacingOccurrences(of: ":", with: "-") }.filter { !$0.contains("/") })
    }

    private func lmStudio(_ collector: inout Collector) -> [ScanItem] {
        [".lmstudio/models", ".cache/lm-studio/models"].flatMap { path -> [ScanItem] in
            collector.children(of: env.home.appendingPathComponent(path)).flatMap { publisher in
                collector.children(of: publisher).filter(FileSystem.isDirectory).map {
                    ScanItem(
                        url: $0, name: "LM Studio · \(publisher.lastPathComponent)/\($0.lastPathComponent)",
                        detail: "À retélécharger si besoin", size: FileSystem.allocatedSize(of: $0)
                    )
                }
            }
        }
    }

    private func huggingFace(_ collector: inout Collector) -> [ScanItem] {
        collector.children(of: env.home.appendingPathComponent(".cache/huggingface/hub"))
            .filter { $0.lastPathComponent.hasPrefix("models--") }
            .map {
                let name = $0.lastPathComponent.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
                return ScanItem(url: $0, name: "Hugging Face · \(name)", detail: "Cache, retéléchargé au besoin", size: FileSystem.allocatedSize(of: $0))
            }
    }
}
