# Verified source fallback

This folder contains the unmodified upstream dav1d 1.5.4 source archive. Its filename is the SHA256 required by the installed Homebrew formula. The archive contains its upstream BSD licence and notices.

The official VideoLAN download succeeds locally, but a hosted release runner returned different bytes. The packager can use this snapshot only for the exact original URL and expected checksum when the download fails or does not match. Every copied archive still passes the original checksum check. Other source versions and unknown hashes have no snapshot fallback.

Keep this narrowly scoped: it is a reproducible source input, not a replacement binary or a reason to relax integrity checks. Remove it when a dependable source mirror or newer dependency makes it unnecessary.
