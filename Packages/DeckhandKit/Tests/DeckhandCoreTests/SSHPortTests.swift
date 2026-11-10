import Testing
@testable import DeckhandCore

struct SSHPortTests {
    let ubuntu = SSHPort.parse("""
    sshd=yes
    ports=22
    portfiles=/etc/ssh/sshd_config
    socket=active
    generator=yes
    firewall=ufw
    rules=22/tcp:allow 443/tcp:allow OpenSSH:limit
    selinux=
    listening=22 53 443
    """)

    @Test func parsesTheServer() {
        #expect(ubuntu.ports == [22])
        #expect(ubuntu.socketActivated && ubuntu.socketGenerator)
        #expect(ubuntu.firewall == .ufw)
        #expect(ubuntu.firewallSSHRules == ["22/tcp:allow", "OpenSSH:limit"])
        #expect(ubuntu.listening.contains(443))
    }

    @Test func checksPorts() {
        #expect(SSHPort.problem(with: 80, on: ubuntu) != nil)
        #expect(SSHPort.problem(with: 22, on: ubuntu) != nil)
        #expect(SSHPort.problem(with: 5432, on: ubuntu) != nil)
        #expect(SSHPort.problem(with: 40022, on: ubuntu) == nil)
        #expect(SSHPort.problem(with: SSHPort.suggestion(avoiding: ubuntu), on: ubuntu) == nil)
    }

    @Test func buildsGuardedSteps() {
        let add = SSHPort.addPort(40022, inspection: ubuntu)
        #expect(add.guardSeconds == SSHPort.guardSeconds)
        #expect(add.apply.contains("ufw allow 40022/tcp"))
        #expect(add.apply.contains("'Port 22' 'Port 40022'"))
        #expect(add.files.contains("/etc/ufw/user.rules"))
        #expect(add.reload.contains("systemctl restart ssh.socket"))
        let close = SSHPort.closeOldPorts(keep: 40022, inspection: ubuntu)
        #expect(close.apply.contains("ufw delete allow '22/tcp'"))
        #expect(close.apply.contains("ufw delete limit 'OpenSSH'"))
        #expect(!close.apply.contains("'Port 22'"))
        // Without the socket generator (Ubuntu 22.10/23.04) the socket gets its own ListenStream override.
        var old = ubuntu; old.socketGenerator = false
        #expect(SSHPort.addPort(40022, inspection: old).apply.contains("ListenStream=40022"))
    }
}
