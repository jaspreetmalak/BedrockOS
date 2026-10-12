# Wireless wire helpers

This original, allocation-free layer decodes infrastructure Beacon and Probe
Response frames into `NetworkKit.wifi.Bss`. It is shared protocol code for future
hardware drivers; it does not submit packets to a radio or claim a connection.

`management.parse(frame, receive_channel, signal_dbm)` accepts a raw management
frame with hardware metadata/FCS removed. The driver must verify FCS and provide
trustworthy channel/RSSI metadata. Frames are limited to 4,096 bytes and 256 IEs.
Source must equal a valid unicast BSSID, fragmented/protected/unsupported header
forms fail, and duplicate SSID/RSN/channel IEs or inconsistent channel facts fail.
SSID bytes are binary; empty/all-zero SSIDs represent hidden networks. DSSS and
HT-operation IEs supply channels; driver receive channel can supply or corroborate
one. This is not a general HE/EHT/6 GHz operation decoder.

RSN decoding bounds every suite/count/optional field. The supported personal
classification is CCMP-128 + PSK, or SAE advertised with management protection
capability. PSK/SAE transition advertisements classify as WPA3 to avoid downgrade;
WPA3 is discovery only and is not an implemented authentication method. Legacy
WPA/WEP, enterprise, unknown cipher/AKM and required PMF for the WPA2 helper remain
unsupported. An RSN IE with privacy disabled is a contradiction. An open result
requires privacy disabled and no RSN or legacy WPA advertisement. Discovery data
is unauthenticated and must not itself authorize a connection. RSN extension
advertisements fail conservatively as unsupported and cannot turn into open.

`wpa2.derivePmk(passphrase,ssid,out)` implements WPA2's 4,096-round PBKDF2-HMAC-SHA1
PMK derivation for printable 8–63 byte passphrases. `derivePtk(pmk,ap,station,
anonce,snonce,out)` implements sorted MAC/nonce SHA1 PRF expansion into the CCMP
48-byte PTK: KCK16, KEK16, TK16. Caller supplies a fresh cryptographically random
SNonce and owns all input/output secret lifetimes; `wpa2.clear` uses volatile
stores. Local helper HMAC contexts/digests are cleared. This does not promise that
every compiler/standard-library temporary or every external copy is erased.

`eapol.parse` bounds exact EAPOL lengths up to 2,048 bytes and recognizes only RSN
pairwise descriptor-v2 CCMP message shapes. `calculateMic`/`verifyMic` implement
HMAC-SHA1-128 with a constant-time tag comparison, without modifying source bytes;
output must not overlap inputs. AP messages carry key length16, station replies0.
`ReplayGuard.acceptInitial` retains
the first unauthenticated M1 counter/ANonce; `acceptAuthenticated` accepts one
strictly newer, same-ANonce M3 with a valid MIC and commits only after validation.
Repeated messages are rejected rather than reinstalled. The association owner
must not reset this ledger inside an exchange. M1 never authenticates a peer.

`keywrap.wrap/unwrap` implements RFC 3394 with a 128-bit KEK and 16–512 bytes of
key data. Unwrap checks the default integrity IV in constant time before copying
plaintext into caller storage. Invalid length, aliasing or integrity failure
does not publish plaintext. Work buffers/key schedules are cleared. Zig AES
side-channel mitigations must remain enabled; the build rejects `.none`.

`handshake.Station.start(Config,Installer)` copies the selected valid WPA2 BSSID,
AP RSN body (at most255 bytes), caller PMK and trusted caller SNonce. The PMK must
correspond to the selected SSID. The caller must supply a fresh cryptographically
random SNonce from an established entropy source; no clock, MAC, counter or test
nonce is substituted. Inputs must not alias the station. Borrowing/copying does
not erase the caller's original PMK or nonce. Reusing this station's last SNonce
is rejected even after abort/reset.

`ingest(source_bssid,destination_mac,eapol_payload)` returns an `Action` containing
a copied, bounded M2/M4 `Response` for the driver-owned sender. The exact L2 peer
and destination must match. M1 derives a PTK and produces MICed M2; M3 requires
newer replay counter, the same ANonce, a valid MIC, successful AES unwrap, exactly
one unchanged AP RSN IE, and exactly one CCMP GTK KDE. GTK index0–3 is supported;
Tx/reserved bits, reserved octet, zero GTK, malformed padding and unsupported KDEs
fail closed. CCMP receive RSC has zero reserved high16 bits. Device `install`
consumes borrowed TK/GTK synchronously; it must never retain their pointers.

`complete()` means **authenticated M3 plus successful device key installation**.
It does not mean radio-connected or that M4 was sent. A backend may report joined
only after validated MAC association, successful M4 submission and confirmed key
installation. No helper emits a connected event. A partially failed `install`
invokes `remove`; failure of that cleanup pins `reset_required` and returns
`DeviceResetRequired`. Restart is forbidden until a trusted backend confirms a
full device reset and calls `resetAfterDeviceReset`. `abort` tears down keys.

Successful installation wipes PMK, PTK, TK and GTK from this station, retaining
only KCK16 for active handshake retransmission authentication. Equal-counter M3
retransmits require identical authenticated bytes; newer counters require a valid
MIC and identical normalized M3 (every byte except replay counter/MIC). Both
produce M4 without reinstalling keys or resetting packet-number/replay state.
Changed nonce, RSN/GTK ciphertext, RSC, flags or version fails; lower counters
fail. M1 retransmits preserve identity and reuse the existing PTK/SNonce while
updating M2's counter. Failure/abort also wipes KCK and cached responses. All
access/callbacks are serialized and non-reentrant; the backend owns deadlines.

`station.MacSession` separately serializes Open System Authentication and
Association requests and validates their responses. The driver supplies its
supported rate intersection, sequence number and listen interval. SSID/rates/RSN
are bounded copied records; responses must match AP/source/destination, status,
infrastructure privacy and valid AID. `associated` is MAC control state only.
Secure nonce sourcing, actual management/EAPOL transmit/retry scheduling, firmware
key programming, DMA, CCMP data encryption and physical RF qualification remain
device-backend responsibilities.

The standalone module is `ieee80211`, artifact `bedrock-ieee80211`. `zig build test
check` runs native tests/compiles a probe; standard target/optimize and
`-Drelocatable=true` support freestanding PIC checks. Import only `networkkit` when
wiring `root.zig` directly into a larger build.

Format/algorithm references:

- [IEEE 802.11i overview, key hierarchy](https://www.ieee802.org/16/liaison/docs/80211-05_0123r1.pdf).
- [Linux v6.18 IEEE 802.11 wire definitions](https://github.com/torvalds/linux/blob/v6.18/include/linux/ieee80211.h): consulted for format facts only; no implementation or GPL code copied.
- [Pinned hostap RSN/EAPOL declarations](https://android.googlesource.com/platform/external/wpa_supplicant_8/+/android-16.0.0_r1/src/common/wpa_common.h).
- [Pinned hostap numeric PRF/PMK vectors](https://android.googlesource.com/platform/external/wpa_supplicant_8/+/android-16.0.0_r1/src/crypto/crypto_module_tests.c), attributed in `THIRD_PARTY.md`.
- [RFC 2202 HMAC-SHA1 vector](https://www.rfc-editor.org/rfc/rfc2202.html) and [RFC 6070 PBKDF2 vector](https://www.rfc-editor.org/rfc/rfc6070.html).
- [RFC 3394 AES key wrap algorithm/vector](https://www.rfc-editor.org/rfc/rfc3394.html).
- [Pinned hostap AP EAPOL send counter rule](https://android.googlesource.com/platform/external/wpa_supplicant_8/+/android-16.0.0_r1/src/ap/wpa_auth.c): consulted to verify replay counters advance on sends; no implementation copied.

The implementation is from scratch, not a Linux driver port. Published numeric
HMAC, PRF, PMK and AES-wrap vectors provide independent cryptographic expectations;
malformed wire, security downgrade, nonce pinning, replay/retransmission and device
installation rollback tests cover the composition. The deterministic test device
checks protocol callback ownership only and is not a production hardware backend.

An active `handshake.Station` is pinned to its successful initialization address.
Do not move or copy it. Copied/moved objects reject operations with `InvalidOwner`,
report incomplete, erase their own copied secrets, and cannot install/remove the
actual owner's device keys. `resetAfterDeviceReset` is fallible for the same owner
check. The trusted backend must keep the owner alive until abort/reset completes.
