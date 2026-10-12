import Testing
@testable import Steer

struct AgentUsageTests {
    @Test
    func parsesAndTotalsByDay() {
        let output = """
        2026-09-04 output_tokens 100
        2026-09-05 input_tokens 7
        2026-09-05 output_tokens 50
        2026-09-05 cache_read_input_tokens 900
        2026-09-05 cache_creation_input_tokens 30
        garbage line
        """
        let days = AgentUsage.parse(output)
        #expect(days.map(\.date) == ["2026-09-05", "2026-09-04"])
        let today = AgentUsage.totals(days, since: "2026-09-05")
        #expect(today == UsageDay(date: "2026-09-05", input: 7, output: 50, cacheRead: 900, cacheWrite: 30))
        #expect(AgentUsage.totals(days, since: "2026-09-04").output == 150)
    }
}
