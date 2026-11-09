import Testing
@testable import DeckhandCore

@Suite struct DangerCheckTests {
    @Test(arguments: [
        "rm -rf /", "sudo rm -rf ~", "rm -rf ./build && rm -fr node_modules", "mkfs.ext4 /dev/sdb1",
        "dd if=/dev/zero of=/dev/sda bs=1M", "sudo reboot", "shutdown -h now", "apt upgrade -y && reboot", "systemctl reboot",
        "psql -c 'DROP DATABASE prod'", "mysql -e \"truncate table users\"", "git push --force origin main",
        "git push -f", "git reset --hard HEAD~3", "git clean -fdx", "docker system prune -a -f",
        "kubectl delete ns prod", "sudo systemctl stop ssh", "sudo ufw enable", "crontab -r",
        "echo key >> ~/.ssh/authorized_keys",
    ])
    func flags(_ command: String) {
        #expect(DangerCheck.assess(command: command) != nil, "\(command)")
    }

    @Test(arguments: [
        "ls -la", "rm build.log", "rm -r tmp/cache", "git push origin main", "git reset HEAD file.txt", "df -h",
        "docker ps", "systemctl restart nginx", "cat /etc/os-release", "grep -r reboot docs/",
        "kubectl get pods", "npm run build", "echo 'drop it'",
    ])
    func allows(_ command: String) {
        #expect(DangerCheck.assess(command: command) == nil, "\(command)")
    }

    @Test func files() {
        #expect(DangerCheck.assess(ToolCall(id: "1", name: "write_file", input: ["path": "/etc/nginx/nginx.conf", "content": ""])) != nil)
        #expect(DangerCheck.assess(ToolCall(id: "1", name: "edit_file", input: ["path": "~/.ssh/authorized_keys"])) != nil)
        #expect(DangerCheck.assess(ToolCall(id: "1", name: "write_file", input: ["path": "src/app.ts", "content": ""])) == nil)
        #expect(DangerCheck.assess(ToolCall(id: "1", name: "read_file", input: ["path": "/etc/passwd"])) == nil)
    }
}
