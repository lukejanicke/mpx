import Foundation
import CMPV

struct PlaybackSnapshot {
    var position = 0.0
    var duration = 0.0
    var paused = true
    var volume = 100.0
    var muted = false
    var eof = false
    var videoSize = CGSize(width: 16, height: 9)
}

struct MediaTrack {
    let id: Int64
    let type: String
    let label: String
    let selected: Bool
}

enum PlaybackEvent {
    case snapshot(PlaybackSnapshot)
    case loaded
    case videoSize(CGSize)
    case tracks([MediaTrack])
    case failure(String)
}

enum MPXError: LocalizedError {
    case playback(String)
    var errorDescription: String? {
        switch self { case .playback(let text): return text }
    }
}

/// All core access after initialization is confined to this queue. Rendering
/// never waits for it, as required by libmpv's render API.
final class PlaybackEngine {
    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "mpx.playback", qos: .userInitiated)
    private var state = PlaybackSnapshot()
    private var requestedVolume = 100.0
    private var requestedMute = false
    private var usesOutputControls = false
    var onEvent: ((PlaybackEvent) -> Void)?

    init(headless: Bool = false) throws {
        guard let core = mpv_create() else { throw MPXError.playback("Could not create the playback engine.") }
        handle = core
        var options = [
            "config": "no", "load-scripts": "no", "osc": "no", "osd-level": "0",
            "input-default-bindings": "no", "input-vo-keyboard": "no", "input-terminal": "no",
            "terminal": "no", "vo": "libmpv", "idle": "yes", "keep-open": "yes",
            "keep-open-pause": "yes", "hwdec": "auto-safe", "volume-max": "100",
            "ytdl": "no", "autoload-files": "no", "sub-auto": "no",
            "target-colorspace-hint": "no", "access-references": "no"
        ]
        if headless { options["vo"] = "null"; options["ao"] = "null"; options["hwdec"] = "no" }
        for (name, value) in options {
            let status = mpv_set_option_string(core, name, value)
            if status < 0 {
                mpv_terminate_destroy(core)
                handle = nil
                throw MPXError.playback("Could not configure \(name): \(Self.error(status))")
            }
        }
        let status = mpv_initialize(core)
        guard status >= 0 else {
            mpv_terminate_destroy(core)
            handle = nil
            throw MPXError.playback(Self.error(status))
        }
        let properties: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("volume", MPV_FORMAT_DOUBLE),
            ("mute", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG),
            ("ao-volume", MPV_FORMAT_DOUBLE), ("ao-mute", MPV_FORMAT_FLAG),
            ("video-out-params", MPV_FORMAT_NODE), ("track-list", MPV_FORMAT_NODE)
        ]
        for (index, property) in properties.enumerated() {
            mpv_observe_property(core, UInt64(index + 1), property.0, property.1)
        }
        mpv_set_wakeup_callback(core, { context in
            guard let context else { return }
            let engine = Unmanaged<PlaybackEngine>.fromOpaque(context).takeUnretainedValue()
            engine.queue.async { [weak engine] in engine?.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func command(_ values: [String]) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            let strings = values.map { strdup($0) }
            defer { strings.forEach { free($0) } }
            var pointers = strings.map { $0.map { UnsafePointer($0) } }
            pointers.append(nil)
            let result = pointers.withUnsafeMutableBufferPointer { mpv_command(handle, $0.baseAddress) }
            if result < 0 { self.emit(.failure(Self.error(result))) }
        }
    }

    func set(_ property: String, _ value: String) {
        guard property == "volume" || property == "mute" else { command(["set", property, value]); return }
        queue.async { [weak self] in
            guard let self else { return }
            if property == "volume", let volume = Double(value) { self.requestedVolume = volume }
            if property == "mute" { self.requestedMute = value == "yes" }
            self.applyAudioControls()
        }
    }

    /// AVFoundation queues about two seconds of audio. Apply gain at its renderer
    /// so volume and mute affect already-queued samples, rather than future samples.
    /// Its controls are per renderer; this does not change the Mac's system volume.
    private func applyAudioControls() {
        guard let handle else { return }
        var isAVFoundation = false
        if let driver = mpv_get_property_string(handle, "current-ao") {
            isAVFoundation = String(cString: driver) == "avfoundation"
            mpv_free(driver)
        }
        if isAVFoundation {
            // Preserve mpv's cubic volume curve when using the renderer's linear gain.
            let volumeStatus = mpv_set_property_string(handle, "ao-volume", String(pow(max(0, requestedVolume) / 100, 3) * 100))
            let muteStatus = mpv_set_property_string(handle, "ao-mute", requestedMute ? "yes" : "no")
            usesOutputControls = volumeStatus >= 0 && muteStatus >= 0
            if !usesOutputControls {
                // Avoid combining a partial output adjustment with software gain.
                _ = mpv_set_property_string(handle, "ao-volume", "100")
                _ = mpv_set_property_string(handle, "ao-mute", "no")
            }
        } else {
            usesOutputControls = false
        }
        let volumeStatus = mpv_set_property_string(handle, "volume", usesOutputControls ? "100" : String(requestedVolume))
        let muteStatus = mpv_set_property_string(handle, "mute", usesOutputControls ? "no" : (requestedMute ? "yes" : "no"))
        if volumeStatus < 0 { emit(.failure(Self.error(volumeStatus))) }
        if muteStatus < 0 { emit(.failure(Self.error(muteStatus))) }
        state.volume = requestedVolume
        state.muted = requestedMute
        emit(.snapshot(state))
    }

    #if DEBUG
    /// Inspect render geometry in integration tests without querying the core
    /// on AppKit's rendering thread.
    func inspectProperty(_ name: String, completion: @escaping (Any?) -> Void) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { DispatchQueue.main.async { completion(nil) }; return }
            var node = mpv_node()
            // Inspect the property that implements this app's logical audio control.
            let property = self.usesOutputControls && (name == "volume" || name == "mute") ? "ao-" + name : name
            let result = mpv_get_property(handle, property, MPV_FORMAT_NODE, &node)
            var value = result >= 0 ? Self.decode(node) : nil
            if name == "volume", self.usesOutputControls, let gain = value as? Double {
                value = pow(max(0, gain) / 100, 1.0 / 3.0) * 100
            }
            if result >= 0 { mpv_free_node_contents(&node) }
            DispatchQueue.main.async { completion(value) }
        }
    }
    #endif
    func seek(_ position: Double, exact: Bool = true) {
        guard position.isFinite else { return }
        command(["seek", String(max(0, position)), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func load(_ url: URL, resume: Double, volume: Double, muted: Bool) {
        // Per-file start avoids a FILE_LOADED/initial-autoplay resume race.
        command(["loadfile", url.path, "replace", "-1", "start=\(max(0, resume))"])
        set("volume", String(volume))
        set("mute", muted ? "yes" : "no")
        set("pause", "no")
    }

    func shutdown() {
        queue.sync {
            guard let core = handle else { return }
            mpv_set_wakeup_callback(core, nil, nil)
            mpv_terminate_destroy(core)
            handle = nil
        }
    }

    private func emit(_ event: PlaybackEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func drainEvents() {
        guard let handle else { return }
        var changed = false
        while let pointer = mpv_wait_event(handle, 0), pointer.pointee.event_id != MPV_EVENT_NONE {
            let event = pointer.pointee
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED: emit(.loaded)
            case MPV_EVENT_AUDIO_RECONFIG: applyAudioControls()
            case MPV_EVENT_END_FILE:
                if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self), data.pointee.reason == MPV_END_FILE_REASON_ERROR {
                    emit(.failure("Could not play this file: \(Self.error(data.pointee.error))"))
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let namePointer = property.name, let data = property.data else { continue }
                let name = String(cString: namePointer)
                switch name {
                case "time-pos": state.position = data.assumingMemoryBound(to: Double.self).pointee
                case "duration": state.duration = data.assumingMemoryBound(to: Double.self).pointee
                case "pause": state.paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                case "volume":
                    if !usesOutputControls { state.volume = data.assumingMemoryBound(to: Double.self).pointee }
                case "mute":
                    if !usesOutputControls { state.muted = data.assumingMemoryBound(to: Int32.self).pointee != 0 }
                case "ao-volume":
                    // Keep the logical percentage exact despite the renderer's float gain.
                    if usesOutputControls { state.volume = requestedVolume }
                case "ao-mute":
                    if usesOutputControls { state.muted = data.assumingMemoryBound(to: Int32.self).pointee != 0 }
                case "eof-reached": state.eof = data.assumingMemoryBound(to: Int32.self).pointee != 0
                case "video-out-params":
                    let node = Self.decode(data.assumingMemoryBound(to: mpv_node.self).pointee) as? [String: Any] ?? [:]
                    if let width = node["dw"] as? Int64, let height = node["dh"] as? Int64, width > 0, height > 0 {
                        state.videoSize = CGSize(width: Double(width), height: Double(height))
                        emit(.videoSize(state.videoSize))
                    }
                case "track-list":
                    let nodes = Self.decode(data.assumingMemoryBound(to: mpv_node.self).pointee) as? [[String: Any]] ?? []
                    let tracks = nodes.compactMap { node -> MediaTrack? in
                        guard let id = node["id"] as? Int64, let type = node["type"] as? String else { return nil }
                        let description = [node["title"] as? String, node["lang"] as? String, node["codec"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        return MediaTrack(id: id, type: type, label: description.isEmpty ? "Track \(id)" : description,
                                          selected: node["selected"] as? Bool ?? false)
                    }
                    emit(.tracks(tracks))
                default: break
                }
                changed = true
            default: break
            }
        }
        if changed { emit(.snapshot(state)) }
    }

    private static func decode(_ node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING: return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG: return node.u.flag != 0
        case MPV_FORMAT_INT64: return node.u.int64
        case MPV_FORMAT_DOUBLE: return node.u.double_
        case MPV_FORMAT_NODE_ARRAY, MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee, let values = list.values else { return nil }
            if node.format == MPV_FORMAT_NODE_ARRAY { return (0..<Int(list.num)).compactMap { decode(values[$0]) } }
            var result: [String: Any] = [:]
            for index in 0..<Int(list.num) {
                if let key = list.keys?[index], let value = decode(values[index]) { result[String(cString: key)] = value }
            }
            return result
        default: return nil
        }
    }

    private static func error(_ status: Int32) -> String { String(cString: mpv_error_string(status)) }
}
