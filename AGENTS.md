# Local Release Builds

- Use the existing local self-signed identity for both the host
  app and the bundled Guest helper. Do not use ad-hoc signing for local releases.
- Identity: `Govijr Code Signing` in the login keychain.
- Specify its SHA-1 explicitly to keep the same signing identity across builds:
  `2AECB8B345BA4B952EA6D595AAD94CCE4707A35C`.
- Build with:

  ```sh
  CONFIGURATION=release SIGN_IDENTITY=2AECB8B345BA4B952EA6D595AAD94CCE4707A35C bash scripts/build.sh
  ```

- If this identity is unavailable, stop and report the issue. Do not fall back
  to `SIGN_IDENTITY=-` or `scripts/release.sh --local`.
- Keychain access and signature checks may require execution outside the
  sandbox with approval. Verify both app signatures after building.
- Use `security find-identity -p codesigning` without `-v`: this self-signed
  identity is listed as `CSSMERR_TP_NOT_TRUSTED`, so valid-only filtering hides
  it even though codesign can use it. A sandbox lookup may also hide it.
- Do not replace this identity with an Apple Development certificate or create
  a new certificate. Report signing failures rather than changing trust settings.
- This is a self-signed certificate, not a Developer ID distribution
  certificate; signing does not imply Apple notarization.
