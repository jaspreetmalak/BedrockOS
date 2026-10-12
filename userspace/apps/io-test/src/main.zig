//! Native first-profile file, pipe and executable replacement acceptance.
const std = @import("std");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(runtime.panic);
const note = "/container/note.txt";
const exec_path = "/bundle/exec.elf";

noinline fn expect(value: u64, wanted: u64) void {
    runtime.expect(value == wanted);
}

noinline fn denied(value: u64) void {
    runtime.expect(value == abi.errno.permission or value == abi.errno.invalid);
}

noinline fn bytesEqual(actual: []const u8, wanted: []const u8) void {
    runtime.expect(std.mem.eql(u8, actual, wanted));
}

noinline fn files() void {
    const fd = runtime.success(runtime.open(note, abi.open_flags.read | abi.open_flags.write | abi.open_flags.create | abi.open_flags.truncate));
    runtime.expect(fd & abi.fd_tag_file != 0);
    expect(runtime.writeFd(fd, "Bedrock"), 7);
    expect(runtime.seek(fd, 0, abi.seek_whence.set), 0);
    var buffer: [16]u8 = undefined;
    expect(runtime.read(fd, buffer[0..7]), 7);
    bytesEqual(buffer[0..7], "Bedrock");
    expect(runtime.read(fd, buffer[0..1]), 0);
    expect(runtime.seek(fd, -3, abi.seek_whence.current), 4);
    expect(runtime.read(fd, buffer[0..3]), 3);
    bytesEqual(buffer[0..3], "ock");
    expect(runtime.seek(fd, 3, abi.seek_whence.end), 10);
    expect(runtime.writeFd(fd, "Z"), 1);
    expect(runtime.seek(fd, 7, abi.seek_whence.set), 7);
    expect(runtime.read(fd, buffer[0..4]), 4);
    bytesEqual(buffer[0..4], "\x00\x00\x00Z");
    expect(runtime.seek(fd, 0, abi.seek_whence.set), 0);
    expect(runtime.syscall(abi.syscall.read, fd, abi.code, 2), abi.errno.fault);
    expect(runtime.seek(fd, 0, abi.seek_whence.current), 0);
    expect(runtime.syscall(abi.syscall.write, fd, abi.guard, 1), abi.errno.fault);
    expect(runtime.seek(fd, 0, abi.seek_whence.current), 0);
    expect(runtime.syscall(abi.syscall.read, fd, 0, 0), 0);
    expect(runtime.seek(fd, -1, abi.seek_whence.set), abi.errno.invalid);
    expect(runtime.seek(fd, 0, abi.seek_whence.current), 0);
    expect(runtime.close(fd), 0);
    expect(runtime.close(fd), abi.errno.bad_descriptor);
    expect(runtime.syscall(abi.syscall.read, fd, 0, 0), abi.errno.bad_descriptor);

    const reader = runtime.success(runtime.open(note, abi.open_flags.read));
    expect(runtime.writeFd(reader, "!"), abi.errno.permission);
    expect(runtime.read(reader, buffer[0..7]), 7);
    bytesEqual(buffer[0..7], "Bedrock");
    expect(runtime.close(reader), 0);
    expect(runtime.open("/bundle/io.elf", abi.open_flags.write), abi.errno.permission);
    const bundle = runtime.success(runtime.open("/bundle/io.elf", abi.open_flags.read));
    expect(runtime.read(bundle, buffer[0..1]), 1);
    runtime.expect(buffer[0] == 0x7f);
    expect(runtime.writeFd(bundle, "!"), abi.errno.permission);
    expect(runtime.close(bundle), 0);
    denied(runtime.open("/kernel", abi.open_flags.read));
    denied(runtime.open("/container/../bundle/io.elf", abi.open_flags.read));
    expect(runtime.open("/container/missing", abi.open_flags.read), abi.errno.no_entry);
}

noinline fn fileCapacity() void {
    var descriptors: [16]u64 = undefined;
    var count: usize = 0;
    while (count < descriptors.len) : (count += 1) {
        const fd = runtime.open(note, abi.open_flags.read);
        if (abi.isError(fd)) {
            expect(fd, abi.errno.no_memory);
            break;
        }
        descriptors[count] = fd;
    }
    runtime.expect(count > 0 and count < descriptors.len);
    expect(runtime.open(note, abi.open_flags.write | abi.open_flags.truncate), abi.errno.no_memory);
    const stale = descriptors[0];
    expect(runtime.close(stale), 0);
    const replacement = runtime.success(runtime.open(note, abi.open_flags.read));
    runtime.expect(replacement != stale);
    expect(runtime.close(stale), abi.errno.bad_descriptor);
    expect(runtime.open(note, abi.open_flags.read), abi.errno.no_memory);
    var first: [1]u8 = undefined;
    expect(runtime.read(replacement, &first), 1);
    runtime.expect(first[0] == 'B');
    expect(runtime.close(replacement), 0);
    for (descriptors[1..count]) |fd| expect(runtime.close(fd), 0);
}

noinline fn pipePair() abi.PipePair {
    var pair: abi.PipePair = undefined;
    expect(runtime.pipe(&pair), 0);
    runtime.expect(pair.reader & abi.fd_tag_pipe != 0 and pair.writer & abi.fd_tag_pipe != 0 and pair.reader != pair.writer);
    return pair;
}

noinline fn pipes() void {
    expect(runtime.syscall(abi.syscall.pipe, abi.code, 0, 0), abi.errno.fault);
    const pair = pipePair();
    const reader = runtime.success(runtime.dup(pair.reader, abi.descriptor_rights.read));
    runtime.expect(reader != pair.reader);
    expect(runtime.dup(pair.reader, abi.descriptor_rights.write), abi.errno.permission);
    expect(runtime.writeFd(reader, "!"), abi.errno.permission);
    expect(runtime.seek(reader, 0, abi.seek_whence.set), abi.errno.not_seekable);
    var buffer: [256]u8 = @splat(0xab);
    expect(runtime.read(reader, buffer[0..1]), abi.errno.again);
    expect(runtime.writeFd(pair.writer, &buffer), 256);
    expect(runtime.syscall(abi.syscall.read, reader, abi.code, 1), abi.errno.fault);
    expect(runtime.writeFd(pair.writer, "!"), abi.errno.again);
    expect(runtime.read(reader, buffer[0..128]), 128);
    runtime.expect(buffer[0] == 0xab and buffer[127] == 0xab);
    expect(runtime.read(pair.reader, buffer[0..128]), 128);
    expect(runtime.close(pair.reader), 0);
    expect(runtime.writeFd(pair.writer, "pipe"), 4);
    expect(runtime.close(pair.writer), 0);
    expect(runtime.read(reader, buffer[0..4]), 4);
    bytesEqual(buffer[0..4], "pipe");
    expect(runtime.read(reader, buffer[0..1]), 0);
    expect(runtime.close(reader), 0);
    expect(runtime.close(pair.writer), abi.errno.bad_descriptor);

    const orphan = pipePair();
    expect(runtime.close(orphan.reader), 0);
    expect(runtime.writeFd(orphan.writer, "!"), abi.errno.broken_pipe);
    expect(runtime.close(orphan.writer), 0);
}

noinline fn pipeCapacity() void {
    var pairs: [3]abi.PipePair = undefined;
    for (&pairs) |*pair| pair.* = pipePair();
    const first = runtime.success(runtime.dup(pairs[0].reader, abi.descriptor_rights.read));
    var failed: abi.PipePair = .{ .reader = 7, .writer = 11 };
    expect(runtime.pipe(&failed), abi.errno.no_memory);
    runtime.expect(failed.reader == 7 and failed.writer == 11);
    const last = runtime.success(runtime.dup(pairs[0].reader, abi.descriptor_rights.read));
    expect(runtime.dup(pairs[0].reader, abi.descriptor_rights.read), abi.errno.no_memory);
    expect(runtime.close(first), 0);
    expect(runtime.close(last), 0);
    const replacement = pipePair();
    expect(runtime.close(replacement.reader), 0);
    expect(runtime.close(replacement.writer), 0);
    for (pairs) |pair| {
        expect(runtime.close(pair.reader), 0);
        expect(runtime.close(pair.writer), 0);
    }
}

noinline fn pipePeer() void {
    const pair = pipePair();
    const child = runtime.success(runtime.spawnPipe(exec_path, pair.writer));
    expect(runtime.close(pair.writer), 0);
    var payload: u64 = 0;
    var turns: usize = 0;
    while (true) : (turns += 1) {
        runtime.expect(turns < 256);
        const got = runtime.read(pair.reader, std.mem.asBytes(&payload));
        if (got != abi.errno.again) {
            expect(got, 8);
            break;
        }
        expect(runtime.syscall(abi.syscall.yield, 0, 0, 0), 0);
    }
    runtime.expect(payload == abi.test_payload);
    turns = 0;
    while (true) : (turns += 1) {
        runtime.expect(turns < 256);
        const got = runtime.read(pair.reader, std.mem.asBytes(&payload));
        if (got != abi.errno.again) {
            expect(got, 0);
            break;
        }
        expect(runtime.syscall(abi.syscall.yield, 0, 0, 0), 0);
    }
    expect(runtime.syscall(abi.syscall.wait, child, 0, 0), 44);
    expect(runtime.close(pair.reader), 0);
}

export fn bedrock_user_main(parent_pid: u64, inherited_endpoint: u64, launch_arg: u64) callconv(.c) noreturn {
    runtime.markEntry();
    runtime.expect(parent_pid != 0 and inherited_endpoint == 0 and launch_arg == 0);
    const pid = runtime.success(runtime.syscall(abi.syscall.getpid, 0, 0, 0));
    files();
    fileCapacity();
    pipes();
    pipeCapacity();
    pipePeer();
    // Failed replacement leaves this image, its PID and its authority usable.
    const fd = runtime.success(runtime.open(note, abi.open_flags.read));
    expect(runtime.exec("/bundle/not-elf", pid), abi.errno.invalid);
    expect(runtime.syscall(abi.syscall.getpid, 0, 0, 0), pid);
    var byte: [1]u8 = undefined;
    expect(runtime.read(fd, &byte), 1);
    runtime.expect(byte[0] == 'B');
    // Deliberately retain file and pipe handles. Successful exec must close
    // these old-image resources before publishing its fresh launch context.
    _ = pipePair();
    runtime.write("[user] file and pipe io verified\n");
    _ = runtime.exec(exec_path, pid);
    runtime.exit(99);
}
