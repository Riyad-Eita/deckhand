/// Shell that returns once local test servers on these ports answer (a fixed sleep is too short on slow CI runners).
func waitForPorts(_ ports: Int...) -> String {
    ports.map { "i=0; until curl -s -o /dev/null --max-time 1 http://127.0.0.1:\($0)/ || [ $i -ge 200 ]; do i=$((i+1)); sleep 0.1; done" }
        .joined(separator: "; ")
}
