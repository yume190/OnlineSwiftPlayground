// Copyright Marcin Krzyżanowski <marcin@krzyzanowskim.com>

import Basic
import Utility
import FileKit
import Foundation

class BuildToolchain {
    enum Error: Swift.Error {
        case failed(String)
    }

    private let processSet = ProcessSet()

    func build(code: String) throws -> Result<AbsolutePath, Error> {
        let fileSystem = Basic.localFileSystem

        let tempCodeFile = try TemporaryFile(suffix: ".swift")
        let tempOutputPath = AbsolutePath(tempCodeFile.path.asString.appending(".o"))
        try fileSystem.writeFileContents(tempCodeFile.path, bytes: ByteString(encodingAsUTF8: injectCodeText + code))

        var cmd = [String]()
        cmd += ["swift"]
        cmd += ["--driver-mode=swiftc"]
        // cmd += ["-O"]
        cmd += ["-F",FileKit.projectFolder.appending("/Frameworks")]
        cmd += ["-Xlinker","-rpath","-Xlinker",FileKit.projectFolder.appending("/Frameworks")]
        cmd += ["-gnone"]
        cmd += ["-suppress-warnings"]
        cmd += ["-module-name","SwiftPlayground"]
        #if os(macOS)
            cmd += ["-sanitize=address"]
        #endif
        cmd += ["-enforce-exclusivity=checked"]
        cmd += ["-swift-version","4"]
        if let sdkRoot = sdkRoot() {
            cmd += ["-sdk", sdkRoot.asString]
        }
        cmd += ["-o",tempOutputPath.asString]
        cmd += [tempCodeFile.path.asString]

        let process = Basic.Process(arguments: cmd, environment: [:], redirectOutput: true, verbose: false)
        try processSet.add(process)
        try process.launch()
        let result = try process.waitUntilExit()

        switch result.exitStatus {
        case .terminated(let exitCode) where exitCode == 0:
            return Result.success(tempOutputPath)
        case .signalled(let signal):
            return Result.failure(Error.failed("Terminated by signal \(signal)"))
        default:
            return Result.failure(Error.failed(try (result.utf8Output() + result.utf8stderrOutput()).chuzzle() ?? "Terminated."))
        }
    }

    func run(binaryPath: AbsolutePath) throws -> Result<String, Error> {
        var cmd = [String]()
        #if os(macOS)
            // If enabled, use sandbox-exec on macOS. This provides some safety against arbitrary code execution.
            cmd += ["sandbox-exec", "-p", sandboxProfile()]
        #endif
        cmd += [binaryPath.asString]

        let process = Basic.Process(arguments: cmd, environment: [:], redirectOutput: true, verbose: false)
        try processSet.add(process)
        try process.launch()
        let result = try process.waitUntilExit()
        switch result.exitStatus {
        case .terminated(let exitCode) where exitCode == 0:
            return Result.success(try result.utf8Output().chuzzle() ?? "Done.")
        case .signalled(let signal):
            return Result.failure(Error.failed("Terminated by signal \(signal)"))
        default:
            return Result.failure(Error.failed(try (result.utf8Output() + result.utf8stderrOutput()).chuzzle() ?? "Terminated."))
        }
    }

    private var _sdkRoot: AbsolutePath? = nil
    private func sdkRoot() -> AbsolutePath? {
        if let sdkRoot = _sdkRoot {
            return sdkRoot
        }

        // Find SDKROOT on macOS using xcrun.
        #if os(macOS)
            let foundPath = try? Process.checkNonZeroExit(
                args: "xcrun", "--sdk", "macosx", "--show-sdk-path")
            guard let sdkRoot = foundPath?.chomp(), !sdkRoot.isEmpty else {
                return nil
            }
            _sdkRoot = AbsolutePath(sdkRoot)
        #endif

        return _sdkRoot
    }
}

private func sandboxProfile() -> String {
    var output = """
    (version 1)
    (deny default)
    (import \"system.sb\")
    (allow file-read*)
    (allow process*)
    (allow sysctl*)
    (allow file-write*
    """
    for directory in Platform.darwinCacheDirectories() {
        output += "    (regex #\"^\(directory.asString)/org\\.llvm\\.clang.*\")"
        output += "    (regex #\"^\(directory.asString)/xcrun_db.*\")"
    }
    output += ")\n"
    return output

}

let injectCodeText = """
    #if os(Linux)
        import Glibc
    #else
        import Darwin
    #endif

    private let __install_playground_limits = {
        var rcpu = rlimit(rlim_cur: 7, rlim_max: 15) // 7s
        setrlimit(RLIMIT_CPU, &rcpu)
        var rcore = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &rcore)
        var rfsize = rlimit(rlim_cur: 1048576, rlim_max: 1048576) // 1 MB
        setrlimit(RLIMIT_FSIZE, &rfsize)
        var rnofile = rlimit(rlim_cur: 1, rlim_max: 1)
        setrlimit(RLIMIT_NOFILE, &rnofile)
        var rnproc = rlimit(rlim_cur: 1, rlim_max: 1)
        setrlimit(RLIMIT_NPROC, &rnproc)

        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_UTILITY)
    }

    __install_playground_limits()

    @available(*, unavailable, message: "Please don't change limits!")
    public func setrlimit(_: Int32, _: UnsafePointer<rlimit>!) -> Int32 {
        fatalError("unavailable function can't be called")
    }

    """

