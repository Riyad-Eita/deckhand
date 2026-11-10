import Foundation
import Testing
@testable import DeckhandCore

@Suite struct PackageUpdatesTests {
    @Test func parsesAptWithSecurityAndReboot() {
        let out = """
        @@pm apt
        @@kernel 5.15.0-100-generic
        @@newestkernel 5.15.0-105-generic
        @@listage 3
        @@reboot
        @@rebootpkg linux-image-5.15.0-105-generic
        @@rebootpkg linux-base
        @@list
        openssl/jammy-updates,jammy-security 3.0.2-0ubuntu1.15 amd64 [upgradable from: 3.0.2-0ubuntu1.14]
        containerd.io/jammy 2.3.6-1~ubuntu.22.04~jammy amd64 [upgradable from: 1.7.28-1~ubuntu.22.04~jammy]
        WARNING: apt does not have a stable CLI interface.
        """
        let s = PackageUpdates.parse(out)
        #expect(s.manager == "apt")
        #expect(s.updates.map(\.name) == ["openssl", "containerd.io"])
        #expect(s.security.map(\.name) == ["openssl"])
        #expect(s.updates[0].current == "3.0.2-0ubuntu1.14" && s.updates[0].available == "3.0.2-0ubuntu1.15")
        #expect(s.updates[1].source == "jammy" && !s.updates[1].isSecurity)
        #expect(s.rebootRequired)
        #expect(s.rebootReasons == ["linux 5.15.0-105-generic", "linux-base", "linux-image-5.15.0-105-generic"])
        #expect(s.listAgeDays == 3 && s.runningKernel == "5.15.0-100-generic")
    }

    @Test func parsesDnfWithSecurityAdvisories() {
        let out = """
        @@pm dnf
        @@kernel 5.14.0-427.el9.x86_64
        @@newestkernel 5.14.0-427.el9.x86_64
        @@list

        openssl-libs.x86_64          1:3.0.7-27.el9        baseos
        nginx.x86_64                 1:1.20.1-16.el9       appstream

        Obsoleting Packages
        grub2-tools.x86_64           1:2.06-80.el9         baseos
        @@security
        RHSA-2024:1234 Important/Sec. openssl-libs-1:3.0.7-27.el9.x86_64
        """
        let s = PackageUpdates.parse(out)
        #expect(s.manager == "dnf")
        #expect(s.updates.map(\.name) == ["openssl-libs.x86_64", "nginx.x86_64"])
        #expect(s.security.map(\.name) == ["openssl-libs.x86_64"])
        #expect(!s.rebootRequired)
    }

    @Test func upToDateAndUnknownManagers() {
        let s = PackageUpdates.parse("@@pm apt\n@@kernel 6.8.0\n@@list\n")
        #expect(s.updates.isEmpty && !s.rebootRequired && s.manager == "apt")
        #expect(PackageUpdates.parse("@@pm none\n@@kernel 6.1\n").manager == nil)
        // An older kernel file lying around doesn't ask for a restart.
        #expect(!PackageUpdates.parse("@@pm apt\n@@kernel 6.8.0-50\n@@newestkernel 6.8.0-45\n").rebootRequired)
    }

    @Test func nevraNames() {
        #expect(PackageUpdates.packageName(fromNEVRA: "openssl-libs-1:3.0.7-27.el9.x86_64") == "openssl-libs")
        #expect(PackageUpdates.packageName(fromNEVRA: "kernel-5.14.0-427.el9.x86_64") == "kernel")
        #expect(PackageUpdates.packageName(fromNEVRA: "python3-urllib3-1.26.5-5.el9.noarch") == "python3-urllib3")
    }

    @Test func scripts() {
        let all = PackageUpdates.installScript("apt")
        #expect(all.contains("apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade"))
        let some = PackageUpdates.installScript("apt", packages: ["openssl", "libssl3"])
        #expect(some.contains("install --only-upgrade 'openssl' 'libssl3'"))
        #expect(PackageUpdates.installScript("dnf", packages: ["openssl-libs.x86_64"]).contains("dnf -y upgrade 'openssl-libs.x86_64'"))
        #expect(PackageUpdates.installScript("dnf").contains("dnf -y upgrade 2>&1"))
        #expect(PackageUpdates.rebootScript.contains("sleep 3; systemctl reboot"))
        #expect(PackageUpdates.refreshScript("apt").contains("apt-get update"))
    }
}
