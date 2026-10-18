# Firmware wall clock

Bedrock's UEFI loaders on x86-64, ARM64 and RV64 capture firmware `GetTime`
before the final memory-map/`ExitBootServices` sequence. The optional draft v0.6
handoff contains only a validated calendar baseline. No firmware runtime-service
pointer crosses into the application API and no post-exit firmware call is made.

The calendar conversion follows [UEFI 2.11 GetTime](https://uefi.org/specs/UEFI/2.11/08_Services_Runtime_Services.html#gettime):
UEFI uses `UTC = local + TimeZone`. Bedrock reports the conventional offset in
minutes east of UTC, with the opposite sign. Daylight flags are validated; no
extra daylight hour is applied because firmware already reports its current
local date and offset. An unspecified timezone remains explicit local time,
not a guessed UTC timestamp. Missing, unsupported or invalid firmware time,
and reset boot profiles, produce an unavailable snapshot.

`runtime.clockRead(&snapshot)` calls Bedrock64 `clock_read` (0x108). The output
`ClockTime` is a fixed 32-byte record:

| Field | Meaning |
|---|---|
| `seconds: i64` | Unix epoch seconds when the UTC flag is set; firmware local calendar seconds otherwise. |
| `nanoseconds: u32` | Fraction from 0 to 999,999,999. |
| `flags: u32` | Available 1; UTC 2; progress from observed quanta 4; calendar saturated 8. |
| `utc_offset_minutes: i32` | Minutes east of UTC, or 2047 when firmware did not specify it. |
| `reserved: u32` | Always zero. |
| `observed_ticks: u64` | Existing process timer count, also available when wall time is unavailable. |

The syscall returns zero for a successfully copied snapshot. Callers must
check `snapshot.isAvailable()`; zero seconds without the available flag is not
an epoch date. It takes the output address and two reserved zero arguments.
Copyout uses only that process's writable mappings and does not require or grant
device, network, clock-setting or filesystem privileges. Unaligned writable
storage is accepted through a bounded byte copy. Invalid and wrapping ranges,
read-only storage and nonzero reserved arguments fail before any output write.

The current single-CPU process timers report approximately 10 ms hardware
quanta. The kernel adds one second per 100 observed quanta, with fractional
carry, and saturates the supported calendar at 9999-12-31 23:59:59.999999999.
These are observed quanta, not an independent continuously sampled counter;
firmware capture-to-kernel delay, timer rounding, long kernel work and suspend
can introduce drift. This clock is suitable for the initial desktop time
display; synchronized time, configurable timezones, suspend correction and
clock-setting policy remain future work. The systembar can display firmware
local time by adding the supplied offset only when the UTC flag is set.

Portable tests cover leap-century/date and timezone conversion, unknown timezone
and unsupported-clock behavior, all three handoff architecture tags, fractions
and timer carry, maximal tick counts/calendar saturation, reserved fields and
process-local writable copyout. Runtime qualification still uses each named
UEFI/QEMU profile and its firmware's actual time-service availability.
