import Foundation

// MARK: - Owner tables (PR 4 plan §6.5)
//
// Written from each fixture's structure (not from a run) by
// `uitests/tools/gen_tables_swift.py` in the PR 4 data directory, which reads
// `Fixtures/<name>.json`; the sha256 prefix in each comment is of the fixture
// the table was written from (`Fixtures/SHA256SUMS` pins the bytes). Rules:
// - container: every top-level panel, quote, expand, layout section and
//   extension, as a prefix (its whole body is one entry);
// - containerList: the outermost list inside a container (not inside a
//   table or another list), whose rows also count toward
//   `tk2-list-live-rows`;
// - caption: the media id (`PreparedMedia.id`) of every mediaSingle whose
//   caption has content, at any depth (the census checks caption before
//   container, so a caption inside a panel is a caption row);
// - list: the top-level lists (an explicit list, so a container row a table
//   misses is reported as unclassified, never counted as a list row);
// - root: prepared top-level text blocks whose id is not of the `0.<n>`
//   form (the children of a transparent sync block).
// Regenerate and review a table in the commit that changes its fixture.

extension RowOwnerTable {
    /// `"0.<base + slot>"` (plus `".<suffix>"`) for every `period`-sized
    /// block of `count` top-level nodes and every slot in `slots`: the
    /// stress fixtures repeat one 50- or 100-node pattern.
    static func repeating(period: Int, count: Int, slots: [Int], suffix: String = "") -> [String] {
        stride(from: 0, to: count, by: period).flatMap { base in
            slots.compactMap { slot -> String? in
                let index = base + slot
                guard index < count else { return nil }
                return suffix.isEmpty ? "0.\(index)" : "0.\(index).\(suffix)"
            }
        }
    }

    /// `containers-parity` (86 top-level nodes; sha256 528792d1aa41…): 59 container, 12 containerList, 0 caption, 1 list, 1 root.
    static let containersParity = RowOwnerTable(
        container: [
            "0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7", "0.8", "0.10", "0.11", "0.12", "0.15", "0.16", "0.17",
            "0.18", "0.19", "0.20", "0.21", "0.22", "0.23", "0.24", "0.27", "0.28", "0.29", "0.32", "0.33", "0.34",
            "0.35", "0.36", "0.39", "0.40", "0.41", "0.46", "0.47", "0.48", "0.49", "0.52", "0.53", "0.54", "0.55",
            "0.58", "0.59", "0.60", "0.63", "0.64", "0.65", "0.66", "0.67", "0.68", "0.71", "0.72", "0.73", "0.74",
            "0.75", "0.76", "0.77", "0.78", "0.82", "0.83"
        ],
        containerList: [
            "0.63.1", "0.64.0", "0.64.1", "0.64.2", "0.65.0", "0.66.0", "0.66.1", "0.66.2", "0.67.0", "0.68.0.0",
            "0.68.1.0", "0.68.1.1"
        ],
        list: [
            "0.84"
        ],
        root: [
            "0.43.0"
        ]
    )

    /// `containers-dense` (840 top-level nodes; sha256 69d5cbe34441…): 840 container, 295 containerList, 0 caption, 0 list, 0 root.
    static let containersDense = RowOwnerTable(
        container: repeating(period: 1, count: 840, slots: [0]),
        containerList: [
            "0.0.1", "0.2.1", "0.5.0", "0.9.1.0", "0.13.1.0", "0.16.1.0", "0.17.4", "0.20.1", "0.22.1.0", "0.28.3",
            "0.29.0", "0.30.1.0", "0.32.1", "0.34.0.0", "0.35.2", "0.38.3", "0.44.1", "0.48.1.0", "0.51.0.1",
            "0.51.1.2", "0.51.1.3.0", "0.59.0", "0.60.0", "0.64.0", "0.67.1", "0.71.1", "0.72.0.1", "0.72.1.3.1",
            "0.76.0.0", "0.77.1", "0.83.6", "0.87.0.0", "0.89.0", "0.91.1", "0.97.1.2", "0.99.0", "0.100.1.0",
            "0.102.3", "0.104.4", "0.105.0", "0.106.0", "0.109.1", "0.113.0", "0.114.1.0", "0.117.1", "0.120.1",
            "0.125.0", "0.127.0", "0.129.0.1", "0.132.1.0", "0.138.0", "0.144.1.0", "0.146.0", "0.147.0",
            "0.148.0", "0.148.4", "0.156.1.0", "0.159.5", "0.159.7", "0.162.2", "0.163.2.0", "0.169.0",
            "0.174.1.0", "0.175.3", "0.179.2", "0.181.1.0", "0.182.1", "0.185.1", "0.189.0", "0.190.5.0",
            "0.193.0", "0.195.1.0", "0.202.1.1", "0.203.0", "0.207.1", "0.207.3", "0.208.3", "0.210.5", "0.212.0",
            "0.213.1.0", "0.215.1.0", "0.223.0.3", "0.223.1.1", "0.224.0", "0.226.2.0", "0.231.0", "0.235.1",
            "0.236.1", "0.242.0", "0.246.2", "0.248.0", "0.250.5", "0.251.0", "0.254.0", "0.255.1.2", "0.259.0",
            "0.261.1.1.1", "0.269.0", "0.269.4", "0.270.3", "0.273.1", "0.275.0", "0.277.2", "0.279.0.0",
            "0.286.0.0", "0.286.1.1", "0.290.0", "0.292.0", "0.297.1.0", "0.302.2", "0.305.4", "0.308.1",
            "0.310.0.1", "0.313.1", "0.321.0.1", "0.324.1.0", "0.324.1.1.0", "0.326.4", "0.333.1", "0.335.2",
            "0.336.0", "0.339.1.1", "0.340.2", "0.348.0", "0.353.1", "0.354.0", "0.355.0", "0.355.2", "0.357.0",
            "0.360.1.0", "0.363.1.0", "0.371.0", "0.375.1", "0.377.1", "0.380.2", "0.381.1.0", "0.382.7",
            "0.384.1.0", "0.385.1", "0.387.1.0", "0.395.2", "0.396.0", "0.401.1", "0.406.0", "0.408.1.1.0",
            "0.410.2", "0.410.6", "0.413.1", "0.415.1.0", "0.416.5", "0.421.1", "0.421.3", "0.424.0", "0.431.2",
            "0.431.4", "0.432.0", "0.433.1.0", "0.435.0", "0.441.0", "0.442.1", "0.447.1.0", "0.450.1.0",
            "0.454.0.1", "0.461.4", "0.462.0", "0.464.0", "0.466.0", "0.468.0.0", "0.474.0", "0.476.0", "0.479.1",
            "0.481.1", "0.485.0", "0.488.0", "0.488.5.0", "0.490.2", "0.492.1.3.1", "0.496.1.0", "0.499.2.0",
            "0.502.1", "0.504.0", "0.508.0", "0.512.3", "0.512.5", "0.515.1", "0.522.4", "0.522.5.1", "0.523.1",
            "0.530.0", "0.530.3", "0.538.0.0", "0.540.1", "0.542.2", "0.544.6", "0.549.1.0", "0.550.0", "0.550.5",
            "0.553.4", "0.557.2", "0.557.5", "0.560.0", "0.564.1.0", "0.571.0", "0.571.2", "0.575.5", "0.580.1.0",
            "0.582.1", "0.584.0", "0.585.0", "0.589.0", "0.589.2", "0.595.1", "0.599.1", "0.600.1", "0.603.2",
            "0.606.1", "0.607.1", "0.612.1.2", "0.613.1", "0.614.0", "0.618.1.0", "0.628.5", "0.630.1", "0.635.3",
            "0.635.4.1", "0.639.1.0", "0.643.0.2", "0.645.0", "0.646.1.0", "0.651.0", "0.653.0", "0.657.0.0",
            "0.662.2", "0.663.0", "0.665.0", "0.666.2", "0.671.3", "0.673.0", "0.674.0", "0.679.0", "0.685.0.0",
            "0.686.5", "0.689.0", "0.689.2", "0.692.0", "0.695.0", "0.696.0.2", "0.698.5.0", "0.700.0",
            "0.706.1.0", "0.711.0", "0.712.2", "0.718.0", "0.726.1", "0.727.1.1", "0.728.0", "0.734.0", "0.734.2",
            "0.738.1.1", "0.740.1.1", "0.744.1.2.0", "0.749.0", "0.749.1.0", "0.755.1", "0.756.1", "0.757.0",
            "0.763.0", "0.765.1.1", "0.769.1.0", "0.771.6", "0.772.2.0", "0.776.1", "0.778.3", "0.780.1.0",
            "0.782.1", "0.782.5", "0.789.0", "0.789.4", "0.792.2", "0.793.2.2", "0.795.0", "0.799.6.0", "0.803.2",
            "0.803.4", "0.806.0", "0.806.2", "0.809.0", "0.814.1.0", "0.817.2", "0.819.1", "0.823.2", "0.827.3",
            "0.828.1.3.1", "0.830.1", "0.839.2"
        ],
        list: []
    )

    /// `containers-expand` (554 top-level nodes; sha256 38cd67a65adc…): 7 container, 11 containerList, 0 caption, 0 list, 0 root.
    static let containersExpand = RowOwnerTable(
        container: [
            "0.0", "0.305", "0.346", "0.386", "0.427", "0.470", "0.513"
        ],
        containerList: [
            "0.0.1", "0.346.8", "0.346.17", "0.386.8", "0.386.17", "0.427.8", "0.427.17", "0.470.8", "0.470.17",
            "0.513.8", "0.513.17"
        ],
        list: []
    )

    /// `captions-parity` (25 top-level nodes; sha256 dfe7a40ac766…): 3 container, 0 containerList, 19 caption, 0 list, 0 root.
    static let captionsParity = RowOwnerTable(
        container: [
            "0.13", "0.14", "0.15"
        ],
        caption: [
            "0.3.0", "0.4.0", "0.5.0", "0.6.0", "0.7.0", "0.8.0", "0.9.0", "0.10.0", "0.11.0", "0.13.1.0",
            "0.14.0.0.0", "0.15.1.0", "0.17.0", "0.18.0", "0.19.0", "0.20.0", "0.21.0", "0.22.0", "0.23.0"
        ],
        list: []
    )

    /// `kitchen-sink` (37 top-level nodes; sha256 36a42f36a217…): 12 container, 0 containerList, 1 caption, 4 list, 1 root.
    static let kitchenSink = RowOwnerTable(
        container: [
            "0.9", "0.14", "0.15", "0.16", "0.17", "0.18", "0.19", "0.20", "0.22", "0.30", "0.33", "0.34"
        ],
        caption: [
            "0.23.0"
        ],
        list: [
            "0.10", "0.11", "0.28", "0.29"
        ],
        root: [
            "0.36.0"
        ]
    )

    /// `lists-parity` (20 top-level nodes; sha256 6e234ae338fc…): 4 container, 8 containerList, 0 caption, 7 list, 0 root.
    static let listsParity = RowOwnerTable(
        container: [
            "0.14", "0.15", "0.17", "0.18"
        ],
        containerList: [
            "0.14.1", "0.15.0", "0.17.0", "0.17.1", "0.17.2", "0.18.0.0", "0.18.1.0", "0.18.1.1"
        ],
        list: [
            "0.1", "0.3", "0.5", "0.6", "0.8", "0.10", "0.12"
        ]
    )

    /// `code-parity` (34 top-level nodes; sha256 506e06d7066f…): 2 container, 0 containerList, 0 caption, 1 list, 0 root.
    static let codeParity = RowOwnerTable(
        container: [
            "0.31", "0.32"
        ],
        list: [
            "0.30"
        ]
    )

    /// `media-gallery` (301 top-level nodes; sha256 09a3e5fcb382…): 0 container, 0 containerList, 30 caption, 0 list, 0 root.
    static let mediaGallery = RowOwnerTable(
        caption: [
            "0.1.0", "0.11.0", "0.21.0", "0.31.0", "0.41.0", "0.51.0", "0.61.0", "0.71.0", "0.81.0", "0.91.0",
            "0.101.0", "0.111.0", "0.121.0", "0.131.0", "0.141.0", "0.151.0", "0.161.0", "0.171.0", "0.181.0",
            "0.191.0", "0.201.0", "0.211.0", "0.221.0", "0.231.0", "0.241.0", "0.251.0", "0.261.0", "0.271.0",
            "0.281.0", "0.291.0"
        ],
        list: []
    )

    /// `stress-1k` (1000 top-level nodes; sha256 7d143eab005f…): 260 container, 60 containerList, 10 caption, 180 list, 0 root.
    static let stress1k = RowOwnerTable(
        container: repeating(period: 50, count: 1000, slots: [6, 9, 16, 19, 26, 29, 36, 39, 45, 46, 47, 48, 49]),
        containerList: repeating(period: 100, count: 1000, slots: [46], suffix: "0")
            + repeating(period: 100, count: 1000, slots: [49], suffix: "0.1.1")
            + repeating(period: 100, count: 1000, slots: [46], suffix: "1")
            + repeating(period: 100, count: 1000, slots: [98], suffix: "1.1")
            + repeating(period: 100, count: 1000, slots: [46], suffix: "2")
            + repeating(period: 100, count: 1000, slots: [46], suffix: "3"),
        caption: repeating(period: 100, count: 1000, slots: [95], suffix: "0.0"),
        list: repeating(period: 50, count: 1000, slots: [4, 8, 14, 18, 24, 28, 34, 38, 44])
    )

    /// `stress-5k` (5000 top-level nodes; sha256 1134355c2674…): 1300 container, 300 containerList, 50 caption, 900 list, 0 root.
    static let stress5k = RowOwnerTable(
        container: repeating(period: 50, count: 5000, slots: [6, 9, 16, 19, 26, 29, 36, 39, 45, 46, 47, 48, 49]),
        containerList: repeating(period: 100, count: 5000, slots: [46], suffix: "0")
            + repeating(period: 100, count: 5000, slots: [49], suffix: "0.1.1")
            + repeating(period: 100, count: 5000, slots: [46], suffix: "1")
            + repeating(period: 100, count: 5000, slots: [98], suffix: "1.1")
            + repeating(period: 100, count: 5000, slots: [46], suffix: "2")
            + repeating(period: 100, count: 5000, slots: [46], suffix: "3"),
        caption: repeating(period: 100, count: 5000, slots: [95], suffix: "0.0"),
        list: repeating(period: 50, count: 5000, slots: [4, 8, 14, 18, 24, 28, 34, 38, 44])
    )
}
