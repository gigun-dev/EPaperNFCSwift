# Protocol for NFC-Rewritable e-Paper

This document describes the protocol of a name-badge-sized electronic paper device that can be rewritten via NFC.
This document also based on [@alt-core](https://github.com/alt-core)’s [additional researh](https://github.com/alt-core/nfc-eink/blob/3a48ca4fa6b871c802f060c7c537e4cc5032c344/docs/devices.md).

## Implementations

- Swift [EPaperNFCSwift](https://github.com/niw/EPaperNFCSwift) by me
- Python [nfc-eink](https://github.com/alt-core/nfc-eink) by [@alt-core](https://github.com/alt-core)

## NFC Type, Communication Method, and Display Variants

- ISO 14443-A (Type A)
- Application Identifier (AID): `D2760000850101`
- ISO 7816 APDU is used

| Size     | Number of Colors (Bit Depth) | Resolution | Color Index                                                     | Image Orientation |
| -------- | ---------------------------- | ---------- | --------------------------------------------------------------- | -------------------- |
| 2.9-inch | 2 (1-bit)                    | 296 × 128  | `0x00`: Black<br>`0x01`: White                                  | Rotated 90°          |
| 2.9-inch | 4 (2-bit)                    | 296 × 128  | `0x00`: Black<br>`0x01`: White<br>`0x02`: Yellow<br>`0x03`: Red | Rotated 90°          |
| 4.2-inch | 2 (1-bit)                    | 400 × 300  | `0x00`: Black<br>`0x01`: White                                  | Horizontally flipped |
| 4.2-inch | 4 (2-bit)                    | 400 × 300  | `0x00`: Black<br>`0x01`: White<br>`0x02`: Yellow<br>`0x03`: Red | Normal               |

## APDU Commands

### Authentication

**Command**

```
0x00, 0x20, 0x00, 0x01, 0x04, 0x20, 0x09, 0x12, 0x10
```

**Response Status**

- Success: `0x90, 0x00`
- Failure: Any other value

### Get Device Information

**Command**

```
0x00, 0xD1, 0x00, 0x00, 0x00
```

**Response Status**

- Success: `0x90, 0x00`
- Failure: Any other value

**Response Data**

TLV format (1-byte tag, 1-byte length, data…, repeated)

```
Tag: 0xA0
Length: 7
Data: {
  unknown: UInt8,
  numberOfColors: UInt8,
  unknown: UInt8,
  heightInBits: UInt16 (Big-Endian),
  width: UInt16 (Big-Endian)
}

// numberOfColors

- 0x01, 0x47: 2-color, 1 bpp (bits per pixel)
- 0x07: 4-color, 2 bpp

// Display Size

- (width, heightInBits / bpp)

Tag: 0xA1
Length: 7
Data: {
  imageOrientation: UInt8,
  unknown: UInt8[6]
}

// imageOrientation

- 0x00: Rotated 90°
- 0x01: Normal

Tag: 0xC0
Length: 10
Data: {
  name: Char[10]
}

Tag: 0xC1
Length: 4
Data: {
  uid: UInt32 (Big-Endian)
}
```

> [!WARNING]
> `imageOrientation` field is estimation, especially I didn’t see 2.9-inch 4-Color or 4.2-inch 2-Color devices.


### Send Image Data

**Command**

```
0xF0, 0xD3, 0x00, P2, Lc, Data...
```

Details are described later.

**Response Status**

- Success: `0x90, 0x00`
- Failure: Any other value

### Refresh Display

**Command**

```
0xF0, 0xD4, 0x85, P2, 0x00

// P2
0x00: Wait for display refresh to complete (blocking); no need to confirm refresh status separately
0x80: Do not wait for display refresh (non-blocking)
```

Although not documented, iOS Core NFC limits the tag connection to 20 seconds after calling `connect(to:)`. When using non-blocking mode and polling for refresh completion, the operation may exceed 20 seconds, potentially terminating before refresh completes. In blocking mode, the connection is maintained beyond 20 seconds until a response is received.

**Response Status**

- Success: `0x90, 0x00`
- Failure: Any other value

### Confirm Display Refresh

**Command**

```
0xF0, 0xDE, 0x00, 0x00, 0x01
```

- For example, poll at 500 ms intervals.

**Response Status**

- Success: `0x90, 0x00`
- Failure: Any other value

**Response Data**

```
0x00: Refresh complete
0x01: Refresh in progress
```

## Minimal Update Procedure

### When Waiting for Display Refresh (Blocking)

1. Send authentication command `0x00, 0x20, ...` → Success `0x90, 0x00`
2. Send image data `0xF0, 0xD3, ...` → Success `0x90, 0x00` (multiple times)
3. Refresh display `0xF0, 0xD4, 0x85, 0x00, 0x00` → Success `0x90, 0x00`

### When Polling for Display Refresh (Non-Blocking)

1. Send authentication command `0x00, 0x20, ...` → Success `0x90, 0x00`
2. Send image data `0xF0, 0xD3, ...` → Success `0x90, 0x00` (multiple times)
3. Refresh display `0xF0, 0xD4, 0x85, 0x80, 0x00` → Success `0x90, 0x00`
4. Confirm refresh `0xF0, 0xDE, ...` → Success `0x90, 0x00`; repeat until response data becomes `0x00`

## Image Data Format and Transmission Format

### Image Data Preparation

- Determine the number of colors and display size either from the Get Device Information command or by manual selection.
- Prepare bitmap data using color indices: `UInt8[width × height]`.
- For 2.9-inch devices, rotate the image data by 90°.
- For 4.2-inch 2-Color device, flip the image data horizonally.

### Horizontal Packing

Pack the image data row by row, from right to left, into 1 byte per 8 pixels (2-color) or 4 pixels (4-color).

```
// If pixels in a row from right to left are:
p0, p1, p2, p3, p4, p5, p6, p7 ...

// For 2-color (1 bpp):
byte = p0 | (p1 << 1) | (p2 << 2) | (p3 << 3) | (p4 << 4) | ...

// For 4-color (2 bpp):
byte = p0 | (p1 << 2) | (p2 << 4) | (p3 << 6)
```

### Split Packed Data into Blocks

- Divide the packed data into 2,000-byte blocks.
- For 2.9-inch devices, the final block is less than 2,000 bytes.

### Compress Each Block

- Compress each block using `LZO1X-1` (`lzo1x_1_compress`).

### Split Compressed Blocks into Fragments

- Divide each compressed block into 250-byte fragments.
- The final fragment may be less than 250 bytes.

### Transmit Each Fragment Using the Image Data Command

Use the image data command `0xF0, 0xD3, ...` multiple times to send fragments.

```
0xF0, 0xD3, 0x00, P2, Lc, Data...

// P2
0x00: Intermediate fragment of a block
0x01: Final fragment of a block

// Lc
Length of fragment + 2

// Data
{
  blockIndex: UInt8,
  fragmentIndex: UInt8,
  fragment: UInt8[]
}
```
