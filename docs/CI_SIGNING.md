# Prepare CI signing without a powered-on Mac

> Use this workflow only when no Mac is available and the user asked for it in words. The rule is in
> [AGENTS.md](../AGENTS.md) › Build and test.

Use an existing encrypted Apple Distribution `.p12` backup if you have one.
Otherwise, the optional **Prepare signing identity** workflow can generate a
new signing key and Apple Distribution certificate on a hosted macOS runner.
It requires an active Apple Developer membership and an App Store Connect team
API key with certificate-creation permission and access to bighelp. It does not
recover a private key from a downloaded `.cer` or from an unavailable Mac.

## One-time setup from your phone

1. In the private GitHub repository, open **Settings → Secrets and variables →
   Actions**. Save `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY` (the full
   `.p8` PEM text with real newlines). Keep these values out of chat and issues.
2. Generate a unique password using a password manager, preferably 32 random
   characters, and save it as `IOS_DISTRIBUTION_P12_PASSWORD`. Setup enforces
   at least 16 characters and rejects newlines and NUL characters. Preserve this
   password in your password manager for the backup.
3. Once the workflow is on the default branch, open **Actions → Prepare signing
   identity → Run workflow**. Select the reviewed branch and enter exactly
   `CREATE NEW DISTRIBUTION CERTIFICATE`. This requests **one new Apple
   certificate each time**, consuming a certificate slot. It never revokes an
   existing certificate. Do not repeat a successful setup for each release.
4. Download `loopdy-encrypted-signing-<run number>` from the successful run
   **within one day**. On iPhone, unzip it in Files. Open
   `distribution.p12.base64.txt` and copy its complete single-line contents to
   the repository Actions secret `IOS_DISTRIBUTION_P12_BASE64`.
5. Keep the encrypted `distribution.p12` in a trusted backup location and its
   password separately. Delete the Actions artifact after saving both the
   secret and backup; remove temporary phone downloads and clear copied data
   when finished. The artifact expires after one day if not deleted earlier.
6. Start **Internal TestFlight** using the release instructions in
   [DEVELOPMENT.md](DEVELOPMENT.md#hosted-ios-validation-and-testflight).

The workflow is restricted to private repositories because anyone with
repository read access can download its Actions artifacts. The artifact
contains only the password-encrypted P12 and its equivalent base64 text; base64
adds no protection of its own. The password remains a separate Actions secret.
The workflow cannot save the new repository secret for you.

## Failure and recovery

Check the run summary for the Apple certificate ID before retrying. Apple can
create a certificate before local import, encryption, or artifact upload fails.
If no ID is available, inspect Apple Developer Certificates for a certificate
created at the run time. A cancelled or failed run may leave a remote certificate
whose private key is unrecoverable after runner cleanup. Have the account owner
reconcile that specific certificate before making another; this workflow never
automatically revokes certificates or makes room by deleting existing ones.

If Apple refuses creation because the API key lacks permission or the account
has reached its certificate limit, address that in the Apple developer account
or obtain an existing signing backup. The setup log stays inside the temporary
private directory and is deleted rather than uploaded or printed, so the public
run log gives only a bounded failure message and certificate recovery metadata.

## Implementation and limits

The workflow uses the repository's Fastlane 2.238.0 bundle and the supported
`get_certificates` API-key options with `generate_apple_certs: true` and
`force: true`. Fastlane's intermediate `.p12` file actually contains an
unencrypted PEM private key. The helper explicitly repackages that key with its
matching certificate using Ruby OpenSSL PKCS12, macOS-compatible 3DES password
encryption, and 100,000 encryption/MAC iterations. It validates the certificate's
team and public/private key match and parses the encrypted P12 before export.
Raw signing files, temporary diagnostics, and the ephemeral keychain live only
under `RUNNER_TEMP` and are removed by Ruby cleanup and the workflow's always-run
cleanup step. Abrupt runner loss relies on the hosted runner's destruction.
The App Store Connect private key is passed in memory, never exported.

Setup shares the release concurrency lock. It does not archive or upload an app,
change TestFlight groups, or deploy Hermes. A successful setup establishes
encrypted signing material; only a later successful TestFlight release proves
that the identity can sign the complete app and extensions for distribution.

Sources: [Fastlane 2.238.0 cert runner](https://github.com/fastlane/fastlane/blob/2.238.0/cert/lib/cert/runner.rb),
[supported cert options](https://github.com/fastlane/fastlane/blob/2.238.0/cert/lib/cert/options.rb),
and [get_certificates action](https://github.com/fastlane/fastlane/blob/2.238.0/fastlane/lib/fastlane/actions/get_certificates.rb).
