//! Single-CPU Q35 timer profile: the legacy PIT and cascaded 8259 PIC.
//! These fixed I/O ports are a named-platform contract, not ACPI discovery.
const protocol = @import("boot_protocol");

pub const vector: u8 = 32;
pub const interrupt_id: u64 = 0;
pub const frequency_hz: u32 = 1_193_182;
pub const quantum_count: u16 = 11_932; // Approximately 10 ms, one terminal-count edge.
const pic_command: u16 = 0x20;
const pic_mask: u16 = 0x21;
const slave_command: u16 = 0xa0;
const slave_mask: u16 = 0xa1;
const pit_counter: u16 = 0x40;
const pit_control: u16 = 0x43;

extern fn bedrock_pc_in8(port: u16) callconv(.c) u8;
extern fn bedrock_pc_out8(port: u16, value: u8) callconv(.c) void;
extern fn bedrock_x86_legacy_interrupts() callconv(.c) bool;
var prepared = false;
var armed = false;
// Delivery can be masked while the one-shot itself continues counting. A
// terminal edge remains in PIC IRR until an actual IRQ0 acknowledgement.
var quantum_started = false;

fn write(port: u16, value: u8) void {
    bedrock_pc_out8(port, value);
    // Q35 provides the traditional POST delay port. The controller writes
    // remain serialized even on a platform with slower legacy I/O decoding.
    bedrock_pc_out8(0x80, 0);
}

fn initializePic() void {
    write(pic_mask, 0xff);
    write(slave_mask, 0xff);
    write(pic_command, 0x11); // Edge-triggered cascade, ICW4 follows.
    write(slave_command, 0x11);
    write(pic_mask, vector);
    write(slave_mask, vector + 8);
    write(pic_mask, 1 << 2); // Slave is connected to master IRQ2.
    write(slave_mask, 2);
    write(pic_mask, 1); // 8086 mode, explicit EOI, no automatic EOI.
    write(slave_mask, 1);
    write(pic_mask, 0xff);
    write(slave_mask, 0xff);
}

fn terminalCountReached() bool {
    // 8254 read-back: latch channel0 status only. Mode0 OUT remains high
    // after terminal count, including after the 16-bit count itself wraps.
    write(pit_control, 0xe2);
    return bedrock_pc_in8(pit_counter) & 0x80 != 0;
}

pub fn prepare(info: *const protocol.BootInfo) bool {
    if (prepared or info.boot_environment != @backingInt(protocol.BootEnvironment.uefi)) return false;
    // Disable the inherited xAPIC rather than relying on firmware LINT/IOAPIC
    // routing. x2APIC is explicitly unsupported by this legacy named profile.
    if (!bedrock_x86_legacy_interrupts()) return false;
    write(pic_mask, 0xff);
    write(slave_mask, 0xff);
    write(pit_control, 0x30); // Counter 0, low/high bytes, binary mode 0.
    // Replace inherited periodic counting with a bounded mode0 terminal edge.
    // Once OUT is stably high, controller initialization can safely discard
    // its request before the first owned quantum changes OUT back to low.
    write(pit_counter, 1);
    write(pit_counter, 0);
    var polls: u32 = 0;
    while (polls < 10_000_000) : (polls += 1) {
        if (terminalCountReached()) break;
    } else return false;
    initializePic();
    if (bedrock_pc_in8(pic_mask) != 0xff or bedrock_pc_in8(slave_mask) != 0xff) return false;
    prepared = true;
    return true;
}

pub fn arm() void {
    if (!prepared or armed) @panic("invalid PC timer quantum");
    if (!quantum_started) {
        write(pit_control, 0x30);
        write(pit_counter, @truncate(quantum_count));
        write(pit_counter, @truncate(quantum_count >> 8));
        quantum_started = true;
    }
    armed = true;
    write(pic_mask, 0xfe); // Only master IRQ0 is enabled; cascade stays masked.
}

pub fn acknowledge() bool {
    if (!prepared or !armed or !quantum_started) return false;
    write(pic_command, 0x0b); // OCW3: read the in-service register.
    if (bedrock_pc_in8(pic_command) != 1) return false;
    if (!terminalCountReached()) return false;
    armed = false;
    write(pic_mask, 0xff);
    write(pic_command, 0x60); // Specific EOI for master IRQ0 only.
    quantum_started = false;
    return true;
}

pub fn stop() void {
    if (!prepared) return;
    armed = false;
    write(pic_mask, 0xff);
    // Keep the PIT counter and any real pending edge intact across a yield,
    // blocked syscall or task exit. Only acknowledge() consumes the quantum.
}

/// Wait for one real PIT terminal-count edge while CPU IF remains clear.
/// PIC poll mode acknowledges IRQ0 without entering an interrupt handler.
pub fn idleUntilTick() bool {
    if (!prepared or armed) return false;
    const flags = asm volatile ("pushfq; popq %[flags]"
        : [flags] "=r" (-> u64),
        :
        : .{ .memory = true });
    if (flags & (1 << 9) != 0) return false;
    arm();
    defer stop();
    write(pic_command, 0x0a); // OCW3: read IRR without acknowledging it.
    var polls: u32 = 0;
    while (polls < 10_000_000) : (polls += 1) {
        if (bedrock_pc_in8(pic_command) & 1 != 0) {
            write(pic_command, 0x0c); // OCW3 poll consumes the unmasked IRQ.
            if (bedrock_pc_in8(pic_command) != 0x80) return false;
            return acknowledge(); // Verify ISR0, stop source and issue EOI.
        }
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return false;
}
