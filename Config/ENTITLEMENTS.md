# SSH Studio Entitlements

SSH Studio is intentionally not sandboxed for distribution builds at this stage.

The application launches Apple OpenSSH tools such as `/usr/bin/ssh`, `/usr/bin/sftp`,
`/usr/bin/scp`, and `/usr/bin/rsync`, and it works with user-selected local paths
and remote paths. Enabling App Sandbox without a broader file-access and process
execution design would break terminal, SFTP, sync, and screen-sharing workflows.

Distribution builds should use Hardened Runtime with the minimal entitlements in
`SSHStudio.entitlements`. Do not add automation, accessibility, camera,
microphone, location, contacts, calendar, or broad temporary exceptions unless a
specific feature requires them and has been reviewed.
