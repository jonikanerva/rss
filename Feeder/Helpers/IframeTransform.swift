import Foundation

// MARK: - Video Iframe → Thumbnail Replacement

/// Replace known video platform iframes with clickable thumbnail images.
/// Unknown iframes are left untouched (stripped later by HTMLToBlocks or ignored by disabled JS).
nonisolated func replaceVideoIframes(_ html: String) -> String {
  guard html.range(of: "<iframe", options: .caseInsensitive) != nil else { return html }
  let pattern = /(?i)<iframe[^>]+src=["']([^"']+)["'][^>]*(?:\/>|>[^<]*(?:<\/iframe>)?)/
  return html.replacing(pattern) { match in
    let src = String(match.output.1)
    if let replacement = youTubeThumbnailHTML(from: src) {
      return replacement
    }
    return String(match.output.0)
  }
}

// MARK: - YouTube

/// Extract video ID from a YouTube embed URL and return thumbnail HTML.
nonisolated private func youTubeThumbnailHTML(from src: String) -> String? {
  guard let videoID = extractYouTubeVideoID(from: src) else { return nil }
  let thumbnailURL = "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
  let watchURL = "https://www.youtube.com/watch?v=\(videoID)"
  return
    "<a href=\"\(watchURL)\" class=\"video-thumbnail\"><img src=\"\(thumbnailURL)\" alt=\"Video\"><span class=\"play-icon\">\u{25B6}</span></a>"
}

private enum YouTubeConstants {
  nonisolated static let embedHosts: Set<String> = [
    "www.youtube.com", "youtube.com",
    "www.youtube-nocookie.com", "youtube-nocookie.com",
  ]
}

/// Extract video ID from YouTube embed URLs:
/// - https://www.youtube.com/embed/VIDEO_ID
/// - https://youtube-nocookie.com/embed/VIDEO_ID?...
nonisolated func extractYouTubeVideoID(from src: String) -> String? {
  guard let url = URL(string: src),
    let host = url.host(percentEncoded: false)?.lowercased(),
    YouTubeConstants.embedHosts.contains(host),
    url.pathComponents.count >= 3,
    url.pathComponents[1] == "embed"
  else { return nil }
  let videoID = url.pathComponents[2]
  guard !videoID.isEmpty else { return nil }
  return videoID
}
