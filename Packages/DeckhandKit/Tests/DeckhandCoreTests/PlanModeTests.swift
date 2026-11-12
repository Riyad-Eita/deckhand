import Foundation
import Testing
@testable import DeckhandCore

struct PlanModeTests {
    @Test func wrapsAndUnwrapsTheRequest() {
        let w = PlanMode.wrap("Move the shop to port 8081")
        #expect(PlanMode.isPlanRequest(w) && w.contains("```plan") && w.contains("Don't change anything yet"))
        #expect(PlanMode.unwrap(w) == "Move the shop to port 8081")
        #expect(!PlanMode.isPlanRequest("hello") && PlanMode.unwrap("hello") == "hello")
    }

    @Test func readsStepsInEveryListStyle() {
        let reply = """
        I'll switch the upstream and reload nginx.

        ```plan
        - Back up /etc/nginx/sites-available/shop
        2. Change the upstream port to 8081
        - [ ] Test with `nginx -t`, then reload nginx

        ```
        Risk: a typo stops nginx from reloading; the backup makes it quick to undo.
        """
        #expect(PlanMode.steps(in: reply) == ["Back up /etc/nginx/sites-available/shop", "Change the upstream port to 8081", "Test with `nginx -t`, then reload nginx"])
        let rest = PlanMode.strippingPlan(reply)
        #expect(rest.hasPrefix("I'll switch") && rest.hasSuffix("quick to undo.") && !rest.contains("```"))
        #expect(PlanMode.steps(in: "No plan here.") == nil)
        #expect(PlanMode.steps(in: "```plan\n\n```") == nil)
    }

    @Test func runPromptKeepsTheChosenSteps() {
        let p = PlanMode.runPrompt(["Back up the config", "Reload nginx"])
        #expect(p.contains("1. Back up the config\n2. Reload nginx") && !PlanMode.isPlanRequest(p))
    }

    @Test func planTurnsCantWrite() {
        let names = PlanMode.tools(ServerTools.all(workingDirectory: "~")).map(\.spec.name)
        #expect(names.contains("read_file") && names.contains("run_command"))
        #expect(!names.contains("write_file") && !names.contains("edit_file"))
    }
}
