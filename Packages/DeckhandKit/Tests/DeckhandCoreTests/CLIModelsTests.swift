import Foundation
import Testing
@testable import DeckhandCore

@Suite struct CLIModelsTests {
    @Test func parsesCodexModelList() {
        let json = """
        {"models":[
          {"slug":"model-b","display_name":"Model B","description":"Second","visibility":"list","priority":2,
           "default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}]},
          {"slug":"internal","display_name":"Internal","visibility":"hide","priority":0,"supported_reasoning_levels":[]},
          {"slug":"model-a","display_name":"Model A","description":"First","visibility":"list","priority":1,
           "default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}]}
        ]}
        """
        let models = CLIModels.parseCodex("WARNING: something\n" + json)
        #expect(models.map(\.id) == ["model-a", "model-b"])
        #expect(models[0].name == "Model A" && models[0].efforts == ["low", "max"] && models[0].defaultEffort == "low")
        #expect(models[1].summary == "Second")
        #expect(CLIModels.parseCodex("").isEmpty)
        #expect(CLIModels.parseCodex("error: unknown command").isEmpty)
    }

    @Test func flagsPerCLI() {
        let o = CLIOptions(model: "gpt-x", effort: "high")
        #expect(CLIModels.flags(.codex, o) == " -m 'gpt-x' -c 'model_reasoning_effort=\"high\"'")
        #expect(CLIModels.flags(.claudeCode, CLIOptions(model: "opus", effort: "max")) == " --model 'opus' --effort 'max'")
        #expect(CLIModels.flags(.codex, CLIOptions(model: "", effort: nil)) == "")
        #expect(CLIModels.flags(.claudeCode, CLIOptions(model: "it's", effort: nil)) == " --model 'it'\\''s'")
    }

    @Test func commandsCarryTheOptions() {
        let codex = ServerCLIRun.command(.codex, prompt: "hi", workingDirectory: "/srv", sessionID: "s1", access: .edit,
                                         options: CLIOptions(model: "gpt-x", effort: "low"))
        #expect(codex.contains("-s workspace-write -m 'gpt-x' -c 'model_reasoning_effort=\"low\"' resume 's1'"))
        let claude = ServerCLIRun.command(.claudeCode, prompt: "hi", workingDirectory: "/srv", sessionID: nil, access: .edit,
                                          options: CLIOptions(model: "sonnet", effort: "high"))
        #expect(claude.contains("--permission-mode acceptEdits --model 'sonnet' --effort 'high'"))
        // The resume after a usage limit uses the same model.
        let limited = LimitAwareRun.command(.claudeCode, prompt: "hi", workingDirectory: "/srv", sessionID: nil, access: .edit,
                                            options: CLIOptions(model: "opus"), run: DetachedRun())
        #expect(limited.components(separatedBy: "--model 'opus'").count == 3)
    }
}
