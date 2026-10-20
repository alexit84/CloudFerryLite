# CloudFerryLite

A lightweight native macOS client for **Amazon S3** (and S3-compatible storage) and **SFTP/SSH** servers.
Browse buckets and remote folders like in the Finder, move files in both directions with drag & drop,
preview them with Quick Look and share them with presigned links.

CloudFerryLite is written in SwiftUI with **no third-party dependencies**: S3 requests are signed with a
built-in AWS Signature V4 implementation (CryptoKit), and SFTP speaks protocol version 3 directly over
the system OpenSSH client (`/usr/bin/ssh -s sftp`), so your existing SSH setup just works.

<!--
## Screenshots
Coming soon: docs/screenshots/*.png
-->

## What it does

CloudFerryLite keeps a list of **connections** in its sidebar. Each S3 connection expands into its buckets,
each SFTP connection into its home folder and `/`. Selecting one opens a file browser with a sortable
table (name, size, modification date, kind), a clickable breadcrumb and a toolbar for the common actions.
Uploads, downloads, moves and deletions run in an **Activity** panel with progress and cancellation, so
you can keep browsing while large transfers run.

Folders you visit often can be pinned as **favorites**: they appear at the top of the sidebar and follow
the folder if you rename or move it.

## Features

### Connections
- **S3**: AWS (region-aware, automatic redirect to the bucket's region) or any S3-compatible endpoint
  (MinIO, RustFS, Wasabi, Cloudflare R2, …) with path-style or virtual-hosted addressing.
- **S3 authentication**: access key / secret key, or **AWS SSO (IAM Identity Center)** with browser-based
  device sign-in, account/role picker and automatic renewal of temporary credentials. Profiles can be
  imported from `~/.aws/credentials` and `~/.aws/config`; tokens from `aws sso login` are reused.
- Works with credentials that cannot list buckets: just type the bucket names.
- **SFTP**: host or `~/.ssh/config` alias, optional port, user and start folder. Authentication with
  ssh-agent, keys in `~/.ssh` or an explicit private key, or password. `~/.ssh/config`, `known_hosts`,
  `ProxyJump` and every key type supported by OpenSSH apply.
- Password, key passphrase and unknown host key confirmation are handled by native dialogs
  (CloudFerryLite acts as its own `SSH_ASKPASS` helper).
- Secrets and SSO tokens are stored in the macOS **Keychain**; the connection list contains no secrets.
- "Test connection" before saving.

### Browsing
- Sortable table, folders first, breadcrumb, back / forward / up (⌘[ ⌘] ⌘↑), refresh (⌘R), filter field.
- Large buckets are listed page by page while you browse.
- **Quick Look** preview with the space bar.
- Favorites for buckets and folders (⌘D), renameable and reorderable.
- SFTP symbolic links are shown as such.

### Transfers and file operations
- **Upload** files and folders from an open panel, by **dragging from the Finder** or by pasting files
  copied in the Finder (⌘V).
- **Download** files and folders (recursively) to a folder of your choice, or **drag them to the Finder**
  (native file promises: the download starts when you drop).
- S3 multipart upload for files larger than 64 MB; parallel, pipelined reads and writes on SFTP.
- **Rename**, and **move** with Cut (⌘X) / Paste (⌘V), also between buckets of the same connection.
  When the destination already contains items with the same name you are asked whether to replace them.
- New folder, recursive delete with confirmation, copy `s3://` path or key.
- **Shareable links**: S3 presigned URLs valid from 15 minutes to 7 days.

### Safety details
- Deleting on SFTP never follows symbolic links: a link to a folder is removed as a link, the target is untouched.
- Downloads follow symbolic links and skip the ones that would loop back to a folder already visited.
- Replacing a folder that contains the item being moved is refused.

### Localization
English and Italian; the app follows the system language.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- Swift 6 toolchain (Xcode or the Command Line Tools) to build
- For SFTP: the system OpenSSH client (`/usr/bin/ssh`, included in macOS)

## Build and run

```bash
git clone https://github.com/<your-account>/CloudFerryLite.git
cd CloudFerryLite
./build-app.sh
open dist/CloudFerryLite.app
```

`build-app.sh` compiles in release mode, creates `dist/CloudFerryLite.app` with icon and localizations and
signs it. During development `swift run` also works.

### Code signing and the Keychain

The Keychain grants access per application *signature*. With an ad-hoc signature every build looks like a
different app, so macOS asks again for access to the stored secrets. `build-app.sh` therefore signs with
the first "Apple Development" or "Developer ID Application" certificate found in your keychain (a free
Apple ID added in Xcode is enough); choose a specific one with:

```bash
SIGN_IDENTITY="Apple Development: Name (TEAMID)" ./build-app.sh
```

With a stable identity you answer "Always Allow" once. Without any certificate the script falls back to
ad-hoc signing.

## Where data is stored

| What | Where |
|---|---|
| Connections and favorites (no secrets) | `~/Library/Application Support/CloudFerryLite/state.json` |
| Secret keys, passwords, passphrases, SSO tokens | Login Keychain, service `io.github.alexit84.CloudFerryLite` |
| Preview and drag-and-drop temporary files | `$TMPDIR/CloudFerryLite`, removed on quit |

## Testing

An end-to-end self test exercises each backend against a real server, without the UI: upload of a folder
with Unicode and special characters plus a 70 MB file (multipart on S3), download with byte-by-byte
comparison, rename, folder move, recursive delete; S3 also checks presigned links, SFTP also checks
symbolic links (loops, links to outside folders) and replacing existing destinations.

```bash
# S3-compatible server, e.g.: docker run -p 9000:9000 rustfs/rustfs
# SFTP server, e.g.:          docker run -p 2222:22 atmoz/sftp foo:pass:::upload
CLOUDFERRYLITE_SELFTEST=1 \
  S3_ENDPOINT=http://localhost:9000 S3_KEY=<access-key> S3_SECRET=<secret> \
  SFTP_HOST=localhost SFTP_PORT=2222 SFTP_USER=foo SFTP_PASSWORD=pass SFTP_BASE=upload/ \
  dist/CloudFerryLite.app/Contents/MacOS/CloudFerryLite
```

Use `SFTP_KEY=<path>` instead of `SFTP_PASSWORD` to test key authentication, and `KEEP=1` to leave the
test data on the server. `CLOUDFERRYLITE_DATA_DIR=<dir>` makes the app use a separate data folder, handy to
try it without touching your real connections.

### Translations

Source strings are in English; the Italian translation lives in `Resources/it.lproj/Localizable.strings`.
After changing UI text, check that every key is translated and that placeholders match:

```bash
./scripts/check-localizations.sh
```

## Project layout

```
Sources/CloudFerryLite/
  App.swift              entry point (also handles SSH_ASKPASS mode)
  ContentView.swift      sidebar: favorites, connections, buckets / SFTP roots
  BrowserView.swift      file table, toolbar, context menus, Activity panel, share sheet
  BrowserModel.swift     current location, history, listing
  ConnectionEditor.swift connection form (S3 / SFTP, SSO account picker)
  TransferManager.swift  queue for uploads, downloads, moves, deletes
  FilePromiseDrag.swift  drag to the Finder with NSFilePromiseProvider
  Backends.swift         RemoteBackend protocol, S3 and SFTP implementations
  S3Client.swift         S3 REST API with SigV4 signing, presigned URLs
  SFTP.swift             SFTP v3 client over /usr/bin/ssh
  SSO.swift              AWS IAM Identity Center device authorization flow
  AskPass.swift          password / passphrase / host key dialogs for ssh
  Keychain.swift         Keychain access, ~/.aws profile import
  SelfTest.swift         end-to-end tests
Resources/               localizations
scripts/                 icon generator, localization check
build-app.sh             build, bundle and sign the app
```

## Known limitations

- AWS SSO follows the documented IAM Identity Center OIDC and portal APIs but has not yet been tested
  against a real organization.
- No server-side search: the filter works on the folder currently shown.
- Moving items between different connections is not supported (download and upload instead).

## License

[MIT](LICENSE) © 2026 Alessandro Grechi
