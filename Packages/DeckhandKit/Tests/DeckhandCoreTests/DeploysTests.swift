import Foundation
import Testing
@testable import DeckhandCore

struct DeploysTests {
    @Test func namesAndEnv() {
        #expect(Deploys.App.isValidName("shop-api") && !Deploys.App.isValidName("Shop") && !Deploys.App.isValidName("a b") && !Deploys.App.isValidName("-x"))
        let env = Deploys.env(.init(name: "shop", repo: "git@github.com:me/shop.git", build: "npm ci && npm run build", start: "npm start", keep: 0), topic: "")
        #expect(env.contains("REPO='git@github.com:me/shop.git'") && env.contains("BUILD='npm ci && npm run build'") && env.contains("KEEP='1'"))
        let save = Deploys.saveCommand(.init(name: "shop", repo: "x", autoDeploy: true), topic: "")
        #expect(save.contains("* * * * * $HOME/.deckhand/apps/shop/deploy.sh --if-changed") && save.contains("@reboot $HOME/.deckhand/apps/shop/start.sh"))
        #expect(!Deploys.saveCommand(.init(name: "shop", repo: "x"), topic: "").contains("--if-changed >/dev/null 2>&1 # deckhand-deploy:shop\";"))
    }

    @Test func parsesStatus() {
        let out = """
        @@app shop\tgit@github.com:me/shop.git\tmain\t5\thttp://127.0.0.1:3000/health\tnpm ci\tnpm start
        @@auto
        @@current 20261111-210000-abc1234
        @@running
        @@release 20261111-210000-abc1234
        @@release 20261110-090000-def5678
        @@deploy 1794390000 20261110-090000 def5678 live First version
        @@deploy 1794400000 20261111-210000 abc1234 live Fix the cart
        """
        let s = try! #require(Deploys.parseStatus(out).first)
        #expect(s.app.autoDeploy && s.running && s.liveCommit == "abc1234")
        #expect(s.releases.count == 2 && s.deploys.first?.message == "Fix the cart")
        #expect(s.app.start == "npm start" && s.app.health == "http://127.0.0.1:3000/health")
    }
}
