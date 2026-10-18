# Realtek port provenance and notices

This directory selects the BSD-3-Clause option offered by the pinned Linux v6.18 rtw89 files below. The original dual-license identifiers and copyright notices are retained here. Exact commit `7d0a66e4bb9081d75c82ec4957c50034cb0ea449`, source URLs and SHA-256 hashes are recorded in `upstream.json`. The selected license terms and disclaimer are in [LICENSE](LICENSE); unrelated BedrockOS licenses are unchanged.

The port covers bounded firmware container/image inspection, H2C framing and a targeted PCI inventory. Chip source files were consulted for firmware naming/dependencies; no complete radio transport is implemented.

Vendor firmware reference bytes are not part of this directory or its production artifacts. They were downloaded intact only into `.zig-cache/upstream-wifi/firmware/afabaf773c4c2e2c841429933a6a084a5af4d14d/realtek/` after reviewing their separate license. `firmware-references.json` records the exact files and hashes. Testing interprets the public Linux-defined container layout only; it does not disassemble firmware instructions, execute firmware, or initialize hardware. Any redistribution must meet that separate binary license, including its notices and restrictions. Source-code licensing alone does not authorize modified firmware redistribution.

### drivers/net/wireless/realtek/rtw89/fw.c

```text
// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
/* Copyright(c) 2019-2020  Realtek Corporation
```

### drivers/net/wireless/realtek/rtw89/fw.h

```text
/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause */
/* Copyright(c) 2019-2020  Realtek Corporation
```

### drivers/net/wireless/realtek/rtw89/core.h

```text
/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause */
/* Copyright(c) 2019-2020  Realtek Corporation
```

### drivers/net/wireless/realtek/rtw89/rtw8852ae.c

```text
// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
/* Copyright(c) 2020-2021  Realtek Corporation
```

### drivers/net/wireless/realtek/rtw89/rtw8852be.c

```text
// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
/* Copyright(c) 2020-2022  Realtek Corporation
```

### drivers/net/wireless/realtek/rtw89/rtw8852ce.c

```text
// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
/* Copyright(c) 2020-2022  Realtek Corporation
```

### drivers/net/wireless/realtek/rtw89/rtw8852a.c

```text
// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
/* Copyright(c) 2019-2020  Realtek Corporation
```

### drivers/net/wireless/realtek/rtw89/rtw8852b.c

```text
// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
/* Copyright(c) 2019-2022  Realtek Corporation
```

### drivers/net/wireless/realtek/rtw89/rtw8852c.c

```text
// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
/* Copyright(c) 2019-2022  Realtek Corporation
```
