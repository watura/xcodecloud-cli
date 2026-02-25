# xcodecloud-cli

Terminal UI for Xcode Cloud build management (Zig + libvaxis).

## Requirements

- Zig 0.15.2
- App Store Connect API credentials in env vars:
  - `APPSTORE_CONNECT_API_ISSUER_ID`
  - `APPSTORE_CONNECT_API_KEY_ID`
  - `APPSTORE_CONNECT_API_KEY` (Base64-encoded `.p8` content)

## Run

```bash
zig build run
```

If env vars are missing, the app starts in mock-data mode so the UI flow can still be exercised.
