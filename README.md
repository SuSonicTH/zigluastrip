# zigluastrip

A small command-line tool and Zig library that shrinks Lua source files by
removing unnecessary whitespace and comments.

## Requirements

zigluastrip needs Zig 0.17.0 or newer. Download a release from
[ziglang.org](https://ziglang.org/download/), unpack it, and either add it to your
`PATH` or invoke the build with the full path to the Zig binary.

## Building the executable

```bash
zig build
```

The executable is written to `zig-out/bin/zigluastrip`. For a faster build use:

```bash
zig build -Doptimize=ReleaseFast
```

Run the tests with:

```bash
zig build test
```

## Command-line usage

```
zigluastrip <input_file> <output_file>
```

The input file is read completely, stripped, and written to the output file.
On invalid arguments the tool prints usage information to stderr and exits with
a non-zero status.

## Zig library

Add the package to your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/SuSonicTH/zigluastrip#HEAD
```

Then expose the module in your `build.zig`:

```zig
const zigLuaStrip = b.dependency("zigluastrip", .{
    .target = target,
    .optimize = optimize,
});
```

and import it in your executable or library:

```zig
const exe = b.addExecutable(.{
    .name = "zli",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigLuaStrip", .module = zigLuaStrip.module("zigLuaStrip") },
        },
    }),
});
```

### Stripping a string

```zig
const zigLuaStrip = @import("zigLuaStrip");

const stripped = try zigLuaStrip.strip(source, allocator);
defer allocator.free(stripped);
```

`strip` returns a newly allocated string that the caller owns. It returns an
error for malformed input such as an unterminated string, long string or long
comment.

### Stripping a file

```zig
try zigLuaStrip.file(io, input_path, output_path, allocator);
```

Both path arguments must be NUL-terminated (`[:0]const u8`).

## Stripping at build time

If you want to strip Lua scripts during `zig build`, add zigLuaStrip as a
dependency as described above and add a run step:

```zig
var strip_step = b.addRunArtifact(zigLuaStrip.artifact("zigluastrip"));
strip_step.addArgs(&.{ script.input, script.output });
exe.step.dependOn(&strip_step.step);
```

The artifact name is lowercase (`zigluastrip`); the module name is camelCase
(`zigLuaStrip`).

## Limitations

- zigluastrip is a lexer-level minifier. It does not parse or execute Lua; it
  removes whitespace and comments only where doing so cannot change how the
  surrounding tokens are lexed.
- A leading `#!` shebang line is preserved verbatim, because Lua ignores that
  line.
- Newlines outside strings and comments are not preserved. Lua is
  line-insensitive apart from the shebang line.
- The tool is designed for textual Lua source. Binary input is not supported.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
