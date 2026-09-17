import AVFoundation

enum RecordingFragments {
    /// An early checkpoint, then larger fragments to limit storage overhead.
    /// Exact boundaries depend on codec packets and video keyframes. Recovery
    /// must validate the indexed prefix; these settings alone are not recovery.
    static func configure(_ writer: AVAssetWriter) {
        writer.initialMovieFragmentInterval = CMTime(value: 2, timescale: 1)
        writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)
    }
}
