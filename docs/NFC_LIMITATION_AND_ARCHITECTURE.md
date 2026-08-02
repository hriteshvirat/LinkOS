# LinkOS — NFC Technical Limitation & Architecture Documentation

## 1. Technical Limitation: Why Native Android-to-Mac NFC Unlock is Impossible

Direct NFC tap between an Android phone and a Mac (without external hardware) is **technically impossible** due to hardware and macOS software limitations:

1. **Lack of NFC Reader Hardware**: Most Mac hardware (MacBook Air, MacBook Pro, Mac mini, Mac Studio, Mac Pro) does **not** include an NFC reader chip.
2. **Restricted Secure Element (Apple Pay)**: On Apple devices with NFC (such as iPhones or Apple Watch), the NFC controller is strictly locked to Apple Pay and Apple's Secure Enclave. macOS provides **no public APIs** (`CoreNFC` is an iOS-only framework, not available on macOS).
3. **No Peripheral NFC Target Mode**: macOS cannot act as an ISO/IEC 14443 NFC Target for an Android Initiator without custom external USB NFC reader hardware (such as ACR122U).

---

## 2. LinkOS Secure NFC Architecture Solution

To provide a zero-friction tap-to-action experience without forcing users to buy expensive USB hardware, LinkOS utilizes **passive NFC stickers + Biometric Authentication + Encrypted Wi-Fi/BLE dispatch**.

### Workflow:

```
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│ 1. Passive NFC  │  NDEF │ 2. Android      │ Bio   │ 3. Biometric    │ Enc   │ 4. macOS Host   │
│    Sticker on   ├──────►│    Phone Scans  ├──────►│    Fingerprint/ ├──────►│    Validates &  │
│    Mac          │  Tag  │    Sticker      │ Auth  │    Face Approved│ Command│    Executes     │
└─────────────────┘       └─────────────────┘       └─────────────────┘       └─────────────────┘
```

1. **Physical NFC Tag**: An inexpensive NDEF NFC sticker ($0.50) is placed on the Mac wrist rest or monitor stand.
2. **Phone Scans Tag**: Phone reads the encrypted LinkOS NDEF payload.
3. **Biometric Validation**: `BiometricPrompt` authenticates the user on the phone (Fingerprint/Face unlock).
4. **Encrypted Command Dispatch**: Phone transmits an AES-256-GCM encrypted command over local Wi-Fi (WebSocket) or BLE to the Mac.
5. **Mac Execution**: Mac verifies the HMAC-SHA256 signature and executes the configured action (Unlock, Lock, Open Workspace, Launch Apps, Run Automation, Start Remote Session).
