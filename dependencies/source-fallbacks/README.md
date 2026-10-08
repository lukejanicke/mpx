# Verified source fallback

This folder contains unmodified upstream source archives for dav1d 1.5.4, libplacebo 7.360.1 and x264 commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`. Filenames are the archives' SHA256 hashes. dav1d and libplacebo match their installed Homebrew formula checksums; x264 matches the archive already collected for Homebrew's immutable commit. The archives contain their upstream licences and notices, with copies alongside them.

The official VideoLAN downloads succeed locally, but hosted release runners returned different bytes for dav1d and libplacebo. These snapshots cover the dependency archives on that GitLab host, including x264. The packager can use each snapshot only for its exact version or commit URL and expected checksum when the download fails or does not match. Every copied archive still passes its checksum check. Other source versions and unknown hashes have no snapshot fallback.

Keep this narrowly scoped: it is a reproducible source input, not a replacement binary or a reason to relax integrity checks. Remove it when a dependable source mirror or newer dependency makes it unnecessary.
