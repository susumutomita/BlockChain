const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("foo_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "BlockChain",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "BlockChain",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // また、EVMバイトコードを実行するための専用のステップを追加
    const evm_run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        evm_run_cmd.addArgs(args);
    }
    evm_run_cmd.addArg("--evm");
    evm_run_cmd.addArg("0x608060405260008055348015610014575f80fd5b50610156806100236000396000f3fe608060405234801561001057600080fd5b50600436106100415760003560e01c80636d4ce63c1461004657806383af4f2a14610064578063d09de08a1461007f575b600080fd5b61004e610089565b60405161005b91906100a4565b60405180910390f35b61007d6004803603810190610078919061010d565b610092565b005b610087610098565b005b60008054905090565b8060008190555050565b6000808154809291906100aa9061014e565b9190505550565b6000819050919050565b6100bb816100a8565b82525050565b60006020820190506100d660008301846100b2565b92915050565b600080fd5b6100ea816100a8565b81146100f557600080fd5b50565b600081359050610107816100e1565b92915050565b6000602082840312156101235761012261019c565b5b6000610131848285016100f8565b91505092915050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b6000819050919050565b600061015a826100a8565b91507fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff8203610190576101ef61013b565b5b600182019050919050565b600080fd5b6101a6816100a8565b81146101b157600080fd5b5056fea264697066735822122024c27340b837af144631473252c9e0bdd2b55c5a43d085b201d1d347ce8ff27564736f6c63430008130033");
    const evm_step = b.step("evm", "Run the EVM with a sample counter contract");
    evm_step.dependOn(&evm_run_cmd.step);

    // カウンターをインクリメントする実行ステップも追加
    const evm_inc_cmd = b.addRunArtifact(exe);
    evm_inc_cmd.addArg("--evm");
    evm_inc_cmd.addArg("0x608060405260008055348015610014575f80fd5b50610156806100236000396000f3fe608060405234801561001057600080fd5b50600436106100415760003560e01c80636d4ce63c1461004657806383af4f2a14610064578063d09de08a1461007f575b600080fd5b61004e610089565b60405161005b91906100a4565b60405180910390f35b61007d6004803603810190610078919061010d565b610092565b005b610087610098565b005b60008054905090565b8060008190555050565b6000808154809291906100aa9061014e565b9190505550565b6000819050919050565b6100bb816100a8565b82525050565b60006020820190506100d660008301846100b2565b92915050565b600080fd5b6100ea816100a8565b81146100f557600080fd5b50565b600081359050610107816100e1565b92915050565b6000602082840312156101235761012261019c565b5b6000610131848285016100f8565b91505092915050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b6000819050919050565b600061015a826100a8565b91507fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff8203610190576101ef61013b565b5b600182019050919050565b600080fd5b6101a6816100a8565b81146101b157600080fd5b5056fea264697066735822122024c27340b837af144631473252c9e0bdd2b55c5a43d085b201d1d347ce8ff27564736f6c63430008130033");
    evm_inc_cmd.addArg("--input");
    evm_inc_cmd.addArg("0xd09de08a");  // increment()関数のセレクタ
    const evm_inc_step = b.step("evm-increment", "Run the EVM with increment function call");
    evm_inc_step.dependOn(&evm_inc_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
