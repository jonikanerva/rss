import Foundation

// MARK: - Pure helpers shared between DataWriter and display layers

/// Strip HTML tags and decode entities to produce plain text.
nonisolated func stripHTMLToPlainText(_ html: String) -> String {
  guard !html.isEmpty else { return "" }
  var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
  text = text.replacingOccurrences(of: "&amp;", with: "&")
  text = text.replacingOccurrences(of: "&lt;", with: "<")
  text = text.replacingOccurrences(of: "&gt;", with: ">")
  text = text.replacingOccurrences(of: "&quot;", with: "\"")
  text = text.replacingOccurrences(of: "&#39;", with: "'")
  text = text.replacingOccurrences(of: "&nbsp;", with: " ")
  text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// English ordinal suffix for a day-of-month number (1 → "st", 2 → "nd", 11 → "th", …).
nonisolated func ordinalSuffix(forDay day: Int) -> String {
  switch day {
  case 11, 12, 13: return "th"
  default:
    switch day % 10 {
    case 1: return "st"
    case 2: return "nd"
    case 3: return "rd"
    default: return "th"
    }
  }
}

/// Format the time-of-day portion of an entry for the article-list row as "HH.mm".
/// Uses value-type components + `String(format:)` so no shared mutable formatter exists.
nonisolated func formatEntryTime(_ date: Date) -> String {
  let components = Calendar.current.dateComponents([.hour, .minute], from: date)
  let hour = components.hour ?? 0
  let minute = components.minute ?? 0
  return String(format: "%02d.%02d", hour, minute)
}

/// Format a date for display: "Today, 5th Mar, 21:24" / "Yesterday, 4th Mar" / "Monday, 2nd Mar"
nonisolated func formatEntryDate(_ date: Date) -> String {
  let calendar = Calendar.current
  let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
  let day = calendar.component(.day, from: date)
  let suffix = ordinalSuffix(forDay: day)
  let month = date.formatted(.dateTime.month(.abbreviated))

  if calendar.isDateInToday(date) {
    return "Today, \(day)\(suffix) \(month), \(time)"
  } else if calendar.isDateInYesterday(date) {
    return "Yesterday, \(day)\(suffix) \(month), \(time)"
  } else {
    let weekday = date.formatted(.dateTime.weekday(.wide))
    return "\(weekday), \(day)\(suffix) \(month), \(time)"
  }
}

/// Extract display domain from a URL string, stripping the `www.` prefix.
/// e.g., "https://www.theverge.com/rss" → "theverge.com"
nonisolated func extractDomain(from urlString: String) -> String {
  guard let host = URL(string: urlString)?.host() else { return "" }
  return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// Format a section header label for a given start-of-day date.
/// Used by the article list to show "Today", "Yesterday", or a full weekday/date.
nonisolated func entryListSectionLabel(for date: Date) -> String {
  let calendar = Calendar.current
  if calendar.isDateInToday(date) {
    return "Today"
  } else if calendar.isDateInYesterday(date) {
    return "Yesterday"
  } else {
    let weekday = date.formatted(.dateTime.weekday(.wide))
    let day = calendar.component(.day, from: date)
    let month = date.formatted(.dateTime.month(.wide))
    let year = date.formatted(.dateTime.year())
    return "\(weekday) \(day). \(month) \(year)"
  }
}
