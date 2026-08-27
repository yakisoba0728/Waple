import Foundation

// WE `bin/playliststatetime.bin`(`0x1404780c8`) 의 **읽기·쓰기**.
//
// 무엇을 나르는가
// --------------
// **모니터별 경과시간**이다. WE 는 앱을 껐다 켜도 "이 벽지를 몇 분 봤는지" 를 이어 간다 —
// 기록 지점은 `0x140070690–0x140070dcc` 이고, 값의 출처는 §6.1 의 `elapsed`(`+0x7c`) 그대로다:
//
//     0x140070760  movss xmm6, dword ptr [rbx+0x7c]   ; = elapsed(초)
//     0x14007076c  call 0x14007a1d0                   ; map[monitorName]
//     0x140070771  movss dword ptr [rax], xmm6
//
// 포맷 근거
// --------
// 짝 저장소의 실측 파일 하나다(95바이트, `wallpaper_engine/bin/playliststatetime.bin`,
// `docs/re/playlist-transition.md` §7). 레이아웃이 산술로 정확히 닫힌다 —
// `4+8 + 4 + 4 + 4 + (4+15) + 4 + 3*(4+8+4) = 95`. 그래서 항목 하나짜리 샘플인데도
// 가변 길이 규칙(`u32 길이 + 바이트`)이 확정된다.
//
//     u32 8 · "PLPV0005"     매직(VA 0x1404780b8)
//     u32                    유닉스 시각
//     u32 0                  용도 미상 — 실측 1건이 전부라 **0 으로 쓴다**(§10)
//     u32                    섹션 수
//     섹션마다: u32 길이 + 키("wallpaperconfig") · u32 항목 수
//       항목마다: u32 길이 + 이름("Monitor0") · f32 LE 초
//
// **한계**: 실측 파일이 1개뿐이다. 섹션이 둘 이상인 파일도, `0` 자리가 0 이 아닌 파일도 못 봤다.
// 짝 파일 `bin/playliststate.bin` 은 그 설치본에 아예 없었다 — 같은 직렬화기를 쓴다는 것만 안다.
public enum PlaylistStateTimeFile {

    /// `0x1404780b8`. 버전이 바뀌면 이 문자열이 바뀐다 — 모르는 매직은 **거부**한다
    /// (관용 파스로 다른 버전을 잘못 읽느니 처음부터 다시 세는 게 낫다).
    public static let magic = "PLPV0005"

    /// WE 가 실제로 쓰는 섹션 키. 설정 이름(`wallpaperconfig`)이 그대로 들어간다
    /// (`PTR_s_wallpaperconfig_1404df5a0` → 0x140070690 머리에서 맵 키로 쓰인다).
    public static let defaultSection = "wallpaperconfig"

    /// 한 섹션. `values` 는 **파일 순서를 지킨다** — 스위프트 `Dictionary` 로 받으면
    /// 왕복이 바이트 동일이 안 된다.
    public struct Section: Equatable, Sendable {
        public var key: String
        public var values: [Entry]
        public init(key: String, values: [Entry]) {
            self.key = key
            self.values = values
        }
    }

    /// 모니터 이름 → 경과시간(초).
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var seconds: Float
        public init(name: String, seconds: Float) {
            self.name = name
            self.seconds = seconds
        }
    }

    public struct Contents: Equatable, Sendable {
        /// 파일 머리의 유닉스 시각. 엔진은 이 값을 쓰지 않는 것으로 보이지만(참조를 못 찾았다)
        /// 왕복을 위해 보존한다.
        public var timestamp: UInt32
        public var sections: [Section]
        public init(timestamp: UInt32, sections: [Section]) {
            self.timestamp = timestamp
            self.sections = sections
        }

        /// 기본 섹션의 이름 → 초. 같은 이름이 여러 번 나오면 **뒤가 이긴다**
        /// (맵 직렬화라 원본에 중복이 있을 이유가 없지만, 파일은 신뢰 경계 밖이다).
        public var elapsedByName: [String: Float] {
            var out: [String: Float] = [:]
            for section in sections where section.key == PlaylistStateTimeFile.defaultSection {
                for entry in section.values { out[entry.name] = entry.seconds }
            }
            return out
        }
    }

    // MARK: 쓰기

    public static func encode(_ contents: Contents) -> Data {
        var data = Data()
        appendString(magic, to: &data)
        appendUInt32(contents.timestamp, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(UInt32(clamping: contents.sections.count), to: &data)
        for section in contents.sections {
            appendString(section.key, to: &data)
            appendUInt32(UInt32(clamping: section.values.count), to: &data)
            for entry in section.values {
                appendString(entry.name, to: &data)
                appendUInt32(entry.seconds.bitPattern, to: &data)
            }
        }
        return data
    }

    /// 모니터 이름 → 초 하나를 기본 섹션짜리 파일로. 이름 순으로 정렬해 **같은 상태가 같은
    /// 바이트**가 되게 한다(Dictionary 순회 순서는 실행마다 다르다 — 안 하면 내용이 안 바뀌어도
    /// 파일이 매번 달라져 백업·diff 가 시끄러워진다).
    public static func encode(elapsedByName: [String: Float], timestamp: UInt32) -> Data {
        let entries = elapsedByName.keys.sorted().map { Entry(name: $0, seconds: elapsedByName[$0] ?? 0) }
        return encode(Contents(timestamp: timestamp,
                               sections: [Section(key: defaultSection, values: entries)]))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ text: String, to data: inout Data) {
        let bytes = Array(text.utf8)
        appendUInt32(UInt32(clamping: bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    // MARK: 읽기

    /// 파일은 **신뢰 경계 밖**이다 — 길이가 남은 바이트를 넘으면 트랩하지 않고 `nil` 을 낸다.
    /// 잘린 파일·다른 매직·거대한 길이 필드 전부 여기서 걸린다.
    public static func decode(_ data: Data) -> Contents? {
        var reader = Reader(data)
        guard reader.string() == magic else { return nil }
        guard let timestamp = reader.uint32() else { return nil }
        guard reader.uint32() != nil else { return nil }
        guard let sectionCount = reader.count() else { return nil }
        var sections: [Section] = []
        sections.reserveCapacity(sectionCount)
        for _ in 0..<sectionCount {
            guard let key = reader.string(), let entryCount = reader.count() else { return nil }
            var values: [Entry] = []
            values.reserveCapacity(entryCount)
            for _ in 0..<entryCount {
                guard let name = reader.string(), let bits = reader.uint32() else { return nil }
                values.append(Entry(name: name, seconds: Float(bitPattern: bits)))
            }
            sections.append(Section(key: key, values: values))
        }
        return Contents(timestamp: timestamp, sections: sections)
    }

    /// 한 방향으로만 전진하는 커서. `Data` 는 슬라이스면 `startIndex` 가 0 이 아니라서
    /// 정수 첨자를 그대로 쓰면 조용히 어긋난다 — 그래서 바이트 배열로 복사해 둔다.
    private struct Reader {
        private let bytes: [UInt8]
        private var offset = 0
        init(_ data: Data) { bytes = Array(data) }

        mutating func uint32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            var raw: UInt32 = 0
            for i in (0..<4).reversed() {
                raw = (raw << 8) | UInt32(truncatingIfNeeded: bytes[offset + i])
            }
            offset += 4
            return raw
        }

        /// 길이 필드를 `Int` 로. 남은 바이트보다 크면 `nil` — 그게 상한이다.
        mutating func count() -> Int? {
            guard let raw = uint32(), let value = Int(exactly: raw) else { return nil }
            guard value <= bytes.count - offset else { return nil }
            return value
        }

        mutating func string() -> String? {
            guard let length = count(), offset + length <= bytes.count else { return nil }
            let slice = bytes[offset..<(offset + length)]
            offset += length
            return String(decoding: slice, as: UTF8.self)
        }
    }
}
