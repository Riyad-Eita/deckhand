import Testing
@testable import DeckhandCore

@Suite struct DockerTests {
    static let sample = """
    @@ps
    {"ID":"aaa111","Image":"nginx:alpine","Names":"web","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:80->80/tcp, [::]:80->80/tcp","Labels":"com.docker.compose.project=site,com.docker.compose.service=web"}
    {"ID":"bbb222","Image":"postgres:16","Names":"db","State":"running","Status":"Up 2 hours (healthy)","Ports":"127.0.0.1:5432->5432/tcp","Labels":""}
    {"ID":"ccc333","Image":"worker:1","Names":"worker","State":"exited","Status":"Exited (1) 5 minutes ago","Ports":"","Labels":""}
    {"ID":"ddd444","Image":"job:1","Names":"job","State":"exited","Status":"Exited (0) 1 day ago","Ports":"","Labels":""}
    @@stats
    {"Name":"web","CPUPerc":"0.12%","MemUsage":"6MiB / 8GiB"}
    @@compose
    [{"Name":"site","Status":"running(1)","ConfigFiles":"/srv/site/docker-compose.yml"}]
    """

    @Test func parsesOverview() {
        let o = Docker.parseOverview(Self.sample)
        #expect(o.installed && !o.permissionDenied)
        #expect(o.containers.map(\.name) == ["worker", "db", "web", "job"])
        let web = o.containers.first { $0.name == "web" }!
        #expect(web.composeProject == "site")
        #expect(web.cpu == "0.12%")
        #expect(web.publicPorts == ["0.0.0.0:80"])
        #expect(o.containers.first { $0.name == "db" }!.publicPorts.isEmpty)
        #expect(o.projects == [ComposeProject(name: "site", status: "running(1)", configFiles: ["/srv/site/docker-compose.yml"])])
    }

    @Test func noDockerAndPermission() {
        #expect(!Docker.parseOverview("@@nodocker\n").installed)
        let denied = Docker.parseOverview("@@ps\npermission denied while trying to connect to the docker API at unix:///var/run/docker.sock\n")
        #expect(denied.permissionDenied)
    }

    @Test func commands() {
        #expect(Docker.actionCommand(.remove, container: "web") == "docker rm -f 'web'")
        let p = ComposeProject(name: "site", status: "", configFiles: ["/srv/a b/docker-compose.yml"])
        #expect(Docker.composeCommand(.up, project: p) == "docker compose -p 'site' -f '/srv/a b/docker-compose.yml' up -d 2>&1")
    }
}
