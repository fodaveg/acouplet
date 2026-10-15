from pathlib import Path
import os
import select
import signal
import subprocess
import sys
import tempfile
import time


root = Path(__file__).resolve().parent
capture = (root / "SystemAudioTapProbe.m").read_text()
watch = capture[capture.index("static dispatch_source_t WatchParent("):capture.index("\ntypedef struct", capture.index("static dispatch_source_t WatchParent("))]
observer = (root / "LDACLogObserver.c").read_text()
lifetime = (root / "LDACParentLifetime.h").read_text()
native = (root.parents[1] / "Sources/LDACNativeSession.swift").read_text()
child_code = native[native.index("final class LDACNativeChild {"):native.rindex("#endif")]
fixture = r'''
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static void Interrupt(int value) { interrupted = value; }

__WATCH__
__LIFETIME__

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc > 1 && !strcmp(argv[1], "--exit-23")) return 23;
    if (argc > 1 && !strcmp(argv[1], "--ignore-term")) signal(SIGTERM, SIG_IGN);
    if (argc > 1 && !strcmp(argv[1], "--lifetime-bound")) {
        signal(SIGTERM, SIG_IGN);
        if (!LDACWatchParent(1)) return 1;
    }
    if (argc > 1 && (!strcmp(argv[1], "--capture-watch") || !strcmp(argv[1], "--capture-hung"))) {
        signal(SIGTERM, !strcmp(argv[1], "--capture-hung") ? SIG_IGN : Interrupt);
        dispatch_source_t watcher = WatchParent(getppid());
        if (!watcher) return 1;
        printf("CHILD %d\n", getpid());
        fflush(stdout);
        while (!interrupted) usleep(1000);
        dispatch_source_cancel(watcher);
        puts("CAPTURE_CLEANUP_REACHED");
        return 0;
    }
    printf("CHILD %d\n", getpid());
    fflush(stdout);
    while (1) pause();
}
'''.replace("__WATCH__", watch.replace('8 * NSEC_PER_SEC', 'NSEC_PER_SEC / 4')).replace("__LIFETIME__", lifetime)


def line(process):
    ready, _, _ = select.select([process.stdout], [], [], 5)
    assert ready, "Fixture did not become ready"
    value = process.stdout.readline()
    assert value, "Fixture exited before readiness"
    return value.decode().strip()


def absent(pid):
    for _ in range(100):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.02)
    raise AssertionError(f"Process {pid} survived owner cleanup")


with tempfile.TemporaryDirectory(prefix="acouplet-ldac-owner-exit-") as directory:
    directory = Path(directory)
    child = directory / "Child"
    wrapper = directory / "Observer"
    child_source = directory / "Child.c"
    observer_source = directory / "Observer.c"
    child_source.write_text(fixture)
    observer_source.write_text(observer.replace('"/usr/bin/log"', '"' + str(child) + '"'))
    for source, binary in [(child_source, child), (observer_source, wrapper)]:
        subprocess.run(["xcrun", "clang", "-fblocks", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)], check=True)
    launcher_source = directory / "Launcher.swift"
    launcher = directory / "Launcher"
    launcher_source.write_text("import Foundation\nimport Darwin\n" + child_code + r'''
@main
struct Check {
    static func main() throws {
        let wrapper = URL(fileURLWithPath: CommandLine.arguments[1])
        let child = try LDACNativeChild(executable: wrapper, arguments: ["--ignore-term"], inheritedPCM: nil)
        var descendant: Int32?
        let readyDeadline = DispatchTime.now() + 3
        while descendant == nil && DispatchTime.now() < readyDeadline {
            for line in try child.readLines() where line.hasPrefix("CHILD ") {
                descendant = Int32(line.split(separator: " ")[1])
            }
            usleep(1000)
        }
        precondition(descendant != nil)
        child.signal(SIGKILL)
        let deadline = DispatchTime.now() + 3
        while !child.finished && DispatchTime.now() < deadline {
            child.reap()
            _ = try child.readLines()
            usleep(1000)
        }
        precondition(child.finished)
        print("DESCENDANT \(descendant!)")
    }
}
''')
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(launcher_source), "-o", str(launcher)], check=True)
    result = subprocess.run([str(launcher), str(wrapper)], capture_output=True, text=True, check=True, timeout=5)
    descendant = int(result.stdout.split()[1])
    absent(descendant)
    print("PASS actual child launch/reap kills its isolated process group after supervisor SIGKILL; descendant stdout cannot retain the session")
    sender_source = directory / "Sender.swift"
    sender = directory / "Sender"
    sender_source.write_text("import Foundation\nimport Darwin\n" + child_code + r'''
@main
struct Check {
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let line = String(repeating: "x", count: 256 * 1024)
        let bytes = line.utf8.count + 1
        let counter = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "wc -c"], inheritedPCM: nil)
        try counter.send(line)
        counter.closeInput()
        var counted: [String] = []
        let countDeadline = DispatchTime.now() + 5
        while !counter.outputEnded && DispatchTime.now() < countDeadline {
            counted += try counter.readLines()
            usleep(1000)
        }
        counter.wait()
        precondition(counted.map { $0.trimmingCharacters(in: .whitespaces) } == ["\(bytes)"], "\(counted)")
        let stalled = try LDACNativeChild(executable: fixture, arguments: [], inheritedPCM: nil)
        let started = DispatchTime.now()
        do {
            try stalled.send(line)
            preconditionFailure("A helper that never reads accepted a whole oversized line")
        } catch let error as POSIXError {
            preconditionFailure("A partial write was reported as POSIX error \(error.code.rawValue)")
        } catch {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            precondition(elapsed >= 0.4 && elapsed < 3, "\(elapsed)")
            precondition(error.localizedDescription.contains(" of \(bytes) bytes"), error.localizedDescription)
        }
        stalled.signal(SIGKILL)
        stalled.wait()
        let exited = try LDACNativeChild(executable: fixture, arguments: ["--exit-23"], inheritedPCM: nil)
        exited.wait()
        do {
            try exited.send("stop")
            preconditionFailure("A write to an exited helper succeeded")
        } catch let error as POSIXError {
            precondition(error.code == .EPIPE, "\(error.code)")
        }
        print("SENDER_CHECKS_PASSED")
    }
}
''')
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(sender_source), "-o", str(sender)], check=True)
    result = subprocess.run([str(sender), str(child)], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0 and "SENDER_CHECKS_PASSED" in result.stdout, (result.returncode, result.stdout, result.stderr)
    print("PASS actual child send: a 256 KiB line reaches a reading helper whole, a helper that never reads gets an explicit partial-write error after the bounded wait, and an exited helper is still EPIPE")
    result = subprocess.Popen([str(wrapper), "--exit-23"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    assert result.wait(timeout=5) == 23
    result.stdin.close()
    result.stdout.close()
    for mode in ["--normal", "--ignore-term"]:
        for stop in ["eof", "term", "int"]:
            process = subprocess.Popen([str(wrapper), mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            child_pid = int(line(process).split()[1])
            if stop == "eof":
                process.stdin.close()
            else:
                process.send_signal(signal.SIGTERM if stop == "term" else signal.SIGINT)
            status = process.wait(timeout=5)
            assert status == (1 if mode == "--ignore-term" else 0), status
            absent(child_pid)
            process.stdout.close()
            if stop != "eof":
                process.stdin.close()
            print(f"PASS actual log observer {stop}, child={mode}: child reaped and wrapper exited")
    owner = r'''
import os, subprocess, sys, time
process = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE)
print("OWNER", process.pid, flush=True)
time.sleep(60)
'''
    for binary, mode in [(wrapper, "--normal"), (wrapper, "--ignore-term"), (child, "--capture-watch"), (child, "--capture-hung"), (child, "--lifetime-bound")]:
        process = subprocess.Popen([sys.executable, "-u", "-c", owner, str(binary), mode], stdout=subprocess.PIPE)
        values = [line(process), line(process)]
        observer_pid = int(next(value for value in values if value.startswith("OWNER ")).split()[1])
        child_pid = int(next(value for value in values if value.startswith("CHILD ")).split()[1])
        process.kill()
        process.wait(timeout=5)
        rest = process.communicate(timeout=5)[0].decode()
        absent(observer_pid)
        absent(child_pid)
        if mode == "--capture-watch":
            assert "CAPTURE_CLEANUP_REACHED" in rest
        print(f"PASS actual source owner SIGKILL, mode={mode}: owned processes exited")
    print("PASS process checks use local fixture children; no system log reader, audio, Bluetooth, driver or service accessed")
