//! Build probe only. This is not the kernel entry point.
const kernel = @import("kernel");

comptime {
    _ = @sizeOf(kernel.storage.BlockDevice);
}

export fn bedrock_kernel_probe(header: *const kernel.boot_protocol.Header, available_bytes: usize) callconv(.c) u32 {
    kernel.validateHandoff(header, available_bytes) catch return 0;
    return @backingInt(kernel.arch.kind);
}

export fn bedrock_kernel_memory_probe(info: *const kernel.boot_protocol.BootInfo, available_bytes: usize, limit_exclusive: u64) callconv(.c) u64 {
    info.validate(available_bytes, kernel.arch.kind) catch return 0;
    _ = kernel.memory.summarize(info) catch return 0;
    var pages = kernel.memory.PageCursor.init(info, limit_exclusive);
    return pages.next() orelse 0;
}

/// Compile the allocator's actual implementation for every required ISA.
/// The probe caller supplies accessible bitmap storage; no identity RAM access
/// or architecture initialization occurs in this portable interface library.
export fn bedrock_kernel_allocator_probe(info: *const kernel.boot_protocol.BootInfo, available_bytes: usize, limit_exclusive: u64, bitmap: [*]u8, bitmap_bytes: usize) callconv(.c) u64 {
    info.validate(available_bytes, kernel.arch.kind) catch return 0;
    const layout = kernel.physical_memory.Layout.init(info, limit_exclusive) catch return 0;
    var pages = kernel.physical_memory.Allocator.init(layout, bitmap[0..bitmap_bytes]) catch return 0;
    const address = pages.allocate() orelse return 0;
    pages.release(address) catch return 0;
    const block = (pages.allocateContiguous(2, 2) catch return 0) orelse return 0;
    pages.releaseContiguous(block) catch return 0;
    if (pages.stats().allocated_pages != 0) return 0;
    return address;
}

export fn bedrock_kernel_owned_heap_probe(info: *const kernel.boot_protocol.BootInfo, limit_exclusive: u64, bitmap: [*]u8, bitmap_bytes: usize) callconv(.c) u64 {
    const layout = kernel.physical_memory.Layout.init(info, limit_exclusive) catch return 0;
    var pages = kernel.physical_memory.Allocator.init(layout, bitmap[0..bitmap_bytes]) catch return 0;
    var issuer: kernel.owned_frames.IdIssuer = .{};
    var heap = kernel.kernel_heap.Heap(2).init(&pages, issuer.issue() catch return 0) catch return 0;
    const lease = heap.allocate(4097, 8192) catch return 0;
    const block = heap.resolve(lease) catch return 0;
    heap.release(lease) catch return 0;
    heap.releaseAll() catch return 0;
    return if (pages.stats().allocated_pages == 0) block.range.base else 0;
}

/// Cross-compile portable app policy and handle/quota operations. This probe
/// does not imply userspace, syscall mediation or an active sandbox at boot.
export fn bedrock_kernel_security_probe(app_id: u64, requested: u32, approved: u32, object_id: u64) callconv(.c) u32 {
    const security = kernel.security;
    const profile = security.sandbox.Profile.init(app_id, requested, approved) catch return 0;
    const child = profile.deriveChild(0) catch return 0;
    const grant: security.handles.Grant = .{ .kind = .file, .object_id = object_id, .rights = security.handles.rights.read };
    child.authorizeGrant(grant, .{ .private_container = app_id }) catch return 0;
    var budget = security.quotas.Budget.init(.{ .handles = 2, .processes = 1 });
    budget.reserve(.{ .handles = 2, .processes = 1 }) catch return 0;
    var table: security.handles.Table(2) = .{};
    const token = table.insert(grant) catch return 0;
    _ = table.resolve(token, .file, security.handles.rights.read) catch return 0;
    const duplicate = table.duplicate(token, 0) catch return 0;
    table.restrict(token, 0) catch return 0;
    table.close(token) catch return 0;
    table.close(duplicate) catch return 0;
    budget.release(.{ .handles = 2, .processes = 1 }) catch return 0;
    return @intFromBool(budget.remaining().handles == 2);
}

/// Force native round-robin state transitions through every ISA compile probe.
export fn bedrock_kernel_scheduler_probe() callconv(.c) u32 {
    var queue: kernel.scheduler.Scheduler(2) = .{};
    queue.add(0) catch return 0;
    queue.add(1) catch return 0;
    const first = (queue.dispatch() catch return 0) orelse return 0;
    queue.preempt(first) catch return 0;
    const second = (queue.dispatch() catch return 0) orelse return 0;
    queue.finish(second, .exited) catch return 0;
    queue.stopReady(first, .budget) catch return 0;
    return @intFromBool(first == 0 and second == 1 and queue.ticks == 1);
}

/// Compile process identity, wait/sleep and mailbox lifetimes on every ISA.
export fn bedrock_kernel_process_ipc_probe() callconv(.c) u32 {
    var table: kernel.process.ProcessTable(2) = .{};
    const init = table.spawn(null) catch return 0;
    const child = table.spawn(init) catch return 0;
    var boxes: kernel.ipc.Mailboxes(1, 1) = .{};
    const endpoint = boxes.open(init) catch return 0;
    _ = boxes.send(endpoint, child, "native") catch return 0;
    _ = boxes.receive(endpoint) catch return 0;
    boxes.close(init, endpoint) catch return 0;
    boxes.destroy(endpoint) catch return 0;
    _ = table.dispatch() catch return 0;
    _ = table.wait(init, child) catch return 0;
    _ = table.dispatch() catch return 0;
    table.sleep(child, 1) catch return 0;
    table.advanceTicks(1) catch return 0;
    _ = table.takeWake(child) catch return 0;
    _ = table.dispatch() catch return 0;
    table.exit(child, .{ .code = 42 }) catch return 0;
    _ = table.takeWake(init) catch return 0;
    const record = table.reap(init, child) catch return 0;
    _ = table.slot(child) catch return @intFromBool(record.status.code == 42);
    return 0;
}

export fn bedrock_kernel_user_elf_probe(bytes: [*]const u8, length: usize) callconv(.c) u64 {
    const image = kernel.user_elf.inspect(bytes[0..length], @import("builtin").cpu.arch) catch return 0;
    return image.entry;
}

/// Portable filesystem, authority, descriptor and pipe code is compiled for
/// each supported ISA, independently of architecture trap adapters.
export fn bedrock_kernel_unix_io_probe() callconv(.c) u32 {
    const Fs = kernel.storage.filesystem.ramfs.RamFs(8, 32, 64);
    var storage: kernel.vfs.Vfs(Fs) = .{};
    storage.reset() catch return 0;
    const profile = kernel.security.sandbox.Profile.init(7, 0, 0) catch return 0;
    storage.prepareContainer(profile.app_id) catch return 0;
    storage.mountBundle(profile, "/bundle/program", "ELF", true) catch return 0;
    _ = storage.execPath(profile, "/bundle/program") catch return 0;
    var files = kernel.vfs.Files(1).init(profile) catch return 0;
    const fd = files.open(&storage, profile, "/container/file", .{ .read = true, .write = true, .create = true }) catch return 0;
    _ = files.write(&storage, profile, fd, "test") catch return 0;
    _ = files.seek(&storage, profile, fd, 0, .start) catch return 0;
    var bytes: [4]u8 = undefined;
    _ = files.read(&storage, profile, fd, &bytes) catch return 0;
    files.close(profile, fd) catch return 0;
    var pipes: kernel.pipe.Pipes(1, 4) = .{};
    const object = pipes.create() catch return 0;
    const reader: kernel.pipe.Grant = .{ .object = object, .rights = kernel.pipe.read_right };
    const writer: kernel.pipe.Grant = .{ .object = object, .rights = kernel.pipe.write_right };
    pipes.retain(reader) catch return 0;
    pipes.retain(writer) catch return 0;
    _ = pipes.write(writer, "pipe") catch return 0;
    _ = pipes.read(reader, &bytes) catch return 0;
    _ = pipes.release(reader) catch return 0;
    _ = pipes.release(writer) catch return 0;
    return @intFromBool(pipes.liveCount() == 0 and files.count() == 0);
}
