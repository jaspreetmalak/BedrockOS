# Numeric test-vector attribution

The implementation is original Bedrock code and calls Zig's standard-library
cryptography. No Linux or hostap implementation code was copied. Numeric PRF and
PMK expected outputs in `tests.zig` are from the pinned hostap tests:

https://android.googlesource.com/platform/external/wpa_supplicant_8/+/android-16.0.0_r1/src/crypto/crypto_module_tests.c

Copyright (c) 2014-2015, Jouni Malinen <j@w1.fi>

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name(s) of the above-listed copyright holder(s) nor the names of
   its contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The PBKDF2 numeric prefix vector is from RFC 6070, Copyright (c) 2011 IETF Trust
and the persons identified as document authors. RFC 6070 section 4 identifies
the document as a BSD-licensed Code Component. Its Simplified BSD conditions
require preserving that notice/conditions in source and binary documentation;
the two redistribution conditions and "AS IS" disclaimer above also apply to
this vector (the endorsement condition belongs to the hostap material).

The HMAC-SHA1 numeric vector is from RFC 2202 (P. Cheng and R. Glenn), whose
document states unlimited distribution.

The AES-128 key-wrap numeric vector is RFC 3394 section4.1 (J. Schaad and
R. Housley), Copyright (C) The Internet Society (2002). All Rights Reserved.
The algorithm implementation here is original; no reference implementation was
copied. RFC 3394 states unlimited document distribution and its section9 permits
documents/derivative explanations to be copied with its copyright notice.
