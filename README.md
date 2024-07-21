# zigluastrip
a small commandline tool/library to minimize a lua source script by removing unnessesary whitespaces and comments to compact the source file.

## compile exe
To compile the executable you need zig, tested with zig 0.13.0, it can be downloadad as a single archive from [ziglang.org](https://ziglang.org/download/)

Uncompress the archive and either add it to your path or call the build command with the full path.

To compile the executable call `zig build exe` the resulting executable will be in `zig-out/bin` If you want create a slightly faster release build call `zig build exe -Doptimize=ReleaseFast`

## zig module
To use this as a module in you project create a `build.zig.zon` file, adding zigLuaStrip as dependency.

The url and hash are from the current master version, tested with zig 0.13.0

```zig
.{ 
    .name = "myProject", 
    .version = "0.0.1", 
    .paths = .{""},
    .dependencies = .{ 
        .zigLuaStrip = .{
            .url = "https://github.com/SuSonicTH/zigluastrip/archive/7f8aaac5bd62b7c56c8ad06ed18685599f948d50.tar.gz",
            .hash = "1220f3a40896acfdf242b6d7d16e0658282b1ae708b5cde7ff2eab6fcc96b7e8be24",
        } 
    } 
}
```

and in your `build.zig` add the module as dependecy
```zig
const zigLuaStrip = b.dependency("zigLuaStrip", .{
    .target = target,
    .optimize = optimize,
});
```

and add it as a module to your exe/lib
```zig
//sample exe
const exe = b.addExecutable(.{
    .name = "zli",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

//add module
exe.root_module.addImport("zigLuaStrip", zigLuaStrip.module("zigLuaStrip"));
```

## zigLuaStrip exe as dependency in your build
If you, like me, want to minimize lua source files at zig build time to include them in your binary you can also use this module to run the exe at build time.

Add zigLuaStrip as dependecy in `build.zig.zon` and `build.zig` as described above and then add a run step to do the stripping at compile time.
The artifact name is in lower case, not upper case as the module!!

```zig
var strip_step = b.addRunArtifact(zigLuaStrip.artifact("zigluastrip"));
strip_step.addArgs(&.{ script.input, script.output });
exe.step.dependOn(&strip_step.step);
```
