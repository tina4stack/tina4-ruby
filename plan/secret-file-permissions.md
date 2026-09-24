# Credential file permissions
Outcome: secret persistence creates/hardens0600 files and refuses linked/special targets; credential endpoint behavior stays intact.
- [x] Real filesystem/Rack regression tests fail on original code.
- [x] Reuse bounded internal helper for Auth, DevAdmin and RSA private writer.
- [x] Focused regression/auth/devadmin suites pass; no dependencies added.
## Bugs
Fixed: default umask exposed .env/.env.local/private.pem as0644; currentwritesfollowlinks.
## Commit log
b1d48f401e3674712a60939a94807fff58aba045: signed implementation;16new cases red16→green0;226focusedexamples pass. No dependencies. Final full lab coordinated by root.
