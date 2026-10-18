# MT7922 board facts and factory power

`board.zig` implements an original, allocation-free installed profile decoder and the pinned MT7921/MT7922 factory power response format. It does not make a radio ready from PCI IDs, PHY flags, an EFUSE validity word, or a digest. All tests use synthetic packets and profile bytes; no host radio or RF behavior was tested.

Linux initializes firmware's factory EFUSE mode and combines country, per-rate, SAR, and board limits. It does not require an external certification file. Bedrock's current port has no ACPI AML evaluator for the MTDS, MTGS, MTFG, and MTCL platform tables, and the queried PHY/EFUSE fields do not report antenna gain or a complete calibrated channel/SAR policy. The optional installed profile supplies these missing trusted platform facts. Its provenance digest is optional, its SHA-256 detects accidental changes, and neither is an approval or authentication mechanism. Missing facts keep the current physical boot path unavailable; they never produce automatic transmit permission.

The native boot path checks exact PCI vendor/device, subsystem vendor/device, revision, PHY antenna mask and supported bands, CLC capability, and the actual 16-byte EFUSE block at `0x550` including its raw validity word. It then selects real firmware EFUSE mode. `nic.Client.txPowerInfo()` issues the source CE `GET_TXPWR` command `0xd0` with SET_QUERY `1` and an eight-byte zero request. It copies the correlated 494-byte response into a typed `PowerReport`; it does not invent a generic CID/status acknowledgement for this response.

The report retains USER, EEPROM, and MAC tables, each with 161 signed half-dBm values. `127` in a firmware table means unavailable. `PowerReport.intersect()` can only tighten already trusted per-rate ceilings for the exact current channel, with a matching channel on every table. Unavailable factory rates retain the existing trusted profile ceiling, never an inferred maximum. This is a current-channel report, not an all-channel calibration database. The kernel still applies country/environment policy and the conducted ceiling after antenna gain, board, and SAR restrictions. No 6 GHz, wider bandwidth, or DFS initiation is enabled by this profile.

## Generate an installed profile

Create an explicit JSON document using the fields below, supplying values from the actual installed device and platform. No device is queried by the formatter, and it has no hardware-fact defaults. Synthetic test values are not installable board facts.

```powershell
python tools/make-wifi-board-profile.py actual-board-facts.json MT7922.board
python tools/test-wifi-board-profile.py
```

Existing output requires `--force`; normal publication cannot overwrite another publisher's file. The tool writes ordinary files only and rejects Windows device aliases. The boot-image builder accepts this optional file through `-Dwifi-board-profile=MT7922.board` and installs it at `\EFI\Bedrock\Firmware\MT7922.board`. Use the builder's explicit firmware/profile inputs; the formatter neither mounts media nor writes a host drive. Absence of this profile is an ordinary unavailable-radio case for the current native boot adapter.

The JSON object requires exactly these keys:

- `version`: integer `1`.
- `identity`: `vendor`, `device`, `subsystem_vendor`, `subsystem_device`, `revision`, all integer exact identities. Supported device tuples are `14c3:7922`, `14c3:0616`, and `0b48:7922`; no subsystem/revision wildcard is accepted.
- `hardware`: `antenna_mask` integer `1..3`, `encapsulation` `0..1`, `power_type` `0..1`, `acpi_conf` `0..7`, `mtcl_conf` `0..255`, and boolean `clc_event_supported`. These are supplied facts, not guesses from the PCI tuple.
- `platform`: explicit booleans `opt_in`, `coherent_identity_dma`, `iommu_disabled`, `exclusive_takeover`. All must be true before the current native platform verification succeeds. A false value is preserved and denies that assumption.
- `country`: two uppercase ASCII letters or `00`; `environment`: `unknown`, `indoor`, or `outdoor`. Trusted platform code selects these; applications cannot choose a country.
- `provenance_sha256`: exactly 64 hexadecimal characters, or `null` when no optional provenance identifier is supplied. It is not a qualification gate.
- `efuse`: integer `address` exactly `1360` (`0x550`), integer raw `validity` `0..4294967295`, and `data_hex` exactly 32 hexadecimal characters. Bit 0 of byte 11 must match `encapsulation`.
- `channels`: `1..64` unique records. Each requires `band` (`2ghz` or `5ghz`), integer `channel`, explicit true `available_rx`, `calibrated_rx`, `known_tx_power`, integer `antenna_gain_mbi`, `board_conducted_mbm`, `sar_conducted_mbm`, `max_bandwidth_khz` exactly `20000`, and exactly 161 integer `rates_half_dbm` values in the pinned SKU order. A missing or false fact is rejected instead of defaulted. Every rate must be at or below both conducted ceilings. Use actual per-rate limits; the tool does not generate a flat table.

`mBm` and `mBi` are hundredths of dBm and dBi. Signed half-dBm rates represent 50 mBm per integer step; negative ceilings require rounding down, not toward zero. Gain is bounded to `-20000..20000` mBi; board and SAR conducted ceilings are bounded to the signed firmware range `-6400..6350` mBm. Only standard 20 MHz centers in 2.4 GHz and 5 GHz are accepted.

## Binary format v1

All integers are little-endian. A 128-byte header is followed by `count` 192-byte records, for `320..12416` total bytes. No trailing bytes, omitted facts, duplicate channels, unknown flags, or nonzero reserved bytes are accepted.

| Header offset | Field |
| --- | --- |
| 0 | Eight bytes `BRDBRD01` |
| 8, 10 | u16 version `1`, header size `128` |
| 12 | u32 exact total bytes |
| 16, 18 | u16 channel count `1..64`, record size `192` |
| 20, 22, 24, 26 | u16 vendor, device, subsystem vendor, subsystem device |
| 28..35 | u8 revision, antenna mask, encapsulation, power type, ACPI flags, MTCL configuration, CLC event support, platform flags |
| 36..38 | Two-byte country, u8 environment `0` unknown / `1` indoor / `2` outdoor |
| 39 | Zero |
| 40..71 | SHA-256 of the entire file with these 32 bytes zeroed |
| 72..103 | Optional provenance identifier, zero allowed |
| 104, 108 | u32 EFUSE block address `0x550`, raw validity word |
| 112..127 | Exact 16 EFUSE bytes |

Platform flags are opt-in `1`, coherent identity DMA `2`, IOMMU disabled `4`, and exclusive takeover `8`. They are explicit administrator/platform declarations, never inferred from PCI presence.

| Record offset | Field |
| --- | --- |
| 0, 1 | u8 band `1` 2.4 GHz / `2` 5 GHz, channel |
| 2 | u16 facts `7`: RX available `1`, calibrated RX `2`, known TX power `4` |
| 4, 8, 12 | i32 antenna gain mBi, board conducted mBm, SAR conducted mBm |
| 16 | u32 maximum bandwidth `20000` kHz |
| 20..180 | 161 i8 per-rate ceilings in signed half-dBm |
| 181..191 | Zero |

## Interfaces and verification

`validate(bytes)` is a loader preflight with no large output aggregate or hardware access. `decode(bytes, *Profile)` checks the complete file before changing caller-owned output. `Profile.verify(actual_identity, capabilities, efuse)` binds installed facts to the queried device. `Profile.buildCapabilities(...)` fills caller-owned common channel-capability and MediaTek rate arrays; callers keep the profile immutable and serialize access. `encodeTxPowerQuery`, `decodeTxPowerInfo`, and `PowerReport.rateCeiling/intersect` expose bounded factory facts separately.

Focused native verification passed 78/78 tests in Debug and ReleaseSafe, including the existing MediaTek tests, seven board tests, two new NIC power-query tests, and the wrapper import test. Six emitted PIC probes passed for x86-64, strict-alignment Cortex-A57, and integer RV64 in both modes. The standalone command is:

```powershell
C:/Users/jassm/.zvm/0.17.0/zig.exe test drivers/wifi/src/board_check.zig -O Debug
C:/Users/jassm/.zvm/0.17.0/zig.exe test drivers/wifi/src/board_check.zig -O ReleaseSafe
```

The JSON formatter's seven structural/security/publication tests passed normally and with Python optimization. These receipts cover decoding, source-shaped MCU fixtures, alias rejection, failure atomicity, and cross-compilation. They do not establish physical calibration, firmware interoperability on a card, RF performance, or regulatory compliance.

## Pinned references and licensing

The wire facts come from ISC-licensed Linux v6.18 commit `7d0a66e4bb9081d75c82ec4957c50034cb0ea449`; attribution and cached-file hashes are in [board-provenance.json](board-provenance.json) and the existing [LICENSE](LICENSE). The board profile and formatter are original Bedrock implementations. No ACPI AML or Linux SAR implementation is copied into this decoder.

- [MT7921 MCU query and EFUSE mode](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt7921/mcu.c)
- [Power response structure and SKU rate order](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt7921/mt7921.h)
- [Factory table output and unavailable sentinel](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt7921/debugfs.c)
- [Actual ACPI SAR/geographic/platform inputs](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt792x_acpi_sar.c)
- [Country/SAR/per-rate limit calculation](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt76_connac_mcu.c)
- [6 Mbps hardware rate](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mac80211.c)
