import Foundation

struct UsageDay: Equatable, Sendable {
    var date: String
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
}

enum AgentUsage {
    /// Sums Claude Code's per-message token counts from its own transcripts on the host. Read-only, days are UTC.
    /// Claude only; Codex keeps a different transcript shape under ~/.codex/sessions
    static let command = #"""
    find ~/.claude/projects -name '*.jsonl' -mtime -8 -print0 2>/dev/null | xargs -0 cat 2>/dev/null | awk '
    /"usage"/ {
      d=""; if (match($0,/"timestamp":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) d=substr($0,RSTART+13,10); if (d=="") next
      id=""; if (match($0,/"id":"msg_[A-Za-z0-9]+/)) id=substr($0,RSTART+6,RLENGTH-6)
      if (id!="" && (id in seen)) next; seen[id]=1
      s=$0
      while (match(s,/"(input_tokens|output_tokens|cache_creation_input_tokens|cache_read_input_tokens)":[0-9]+/)) {
        kv=substr(s,RSTART+1,RLENGTH-1); n=index(kv,"\""); k=substr(kv,1,n-1); v=substr(kv,n+2)+0
        t[d SUBSEP k]+=v; s=substr(s,RSTART+RLENGTH)
      }
    }
    END { for (key in t) { split(key,p,SUBSEP); print p[1], p[2], t[key] } }'
    """#

    static func parse(_ output: String) -> [UsageDay] {
        var days: [String: UsageDay] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let value = Int(parts[2]) else { continue }
            let date = String(parts[0])
            var day = days[date] ?? UsageDay(date: date)
            switch parts[1] {
            case "input_tokens": day.input += value
            case "output_tokens": day.output += value
            case "cache_read_input_tokens": day.cacheRead += value
            case "cache_creation_input_tokens": day.cacheWrite += value
            default: continue
            }
            days[date] = day
        }
        return days.values.sorted { $0.date > $1.date }
    }

    static func totals(_ days: [UsageDay], since: String) -> UsageDay {
        days.filter { $0.date >= since }.reduce(UsageDay(date: since)) { acc, day in
            var sum = acc
            sum.input += day.input
            sum.output += day.output
            sum.cacheRead += day.cacheRead
            sum.cacheWrite += day.cacheWrite
            return sum
        }
    }

    static func utcDate(daysAgo: Int, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }
}
