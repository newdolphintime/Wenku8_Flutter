#!/usr/bin/env bash
set -euo pipefail
umask 077

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for target in "$repo/android/key.properties" "$repo/android/wenku-release.p12"; do
    if [ -e "$target" ]; then
        echo "Signing file already exists: $target" >&2
        exit 1
    fi
done

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
password_args=()
if [ -n "${WENKU_BACKUP_PASSWORD:-}" ]; then
    password_args=(-pass env:WENKU_BACKUP_PASSWORD)
fi
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
    -in "$repo/signing/android-release.tar.gz.enc" \
    -out "$temporary/signing.tar.gz" "${password_args[@]}"
tar -xzf "$temporary/signing.tar.gz" -C "$temporary" \
    android/key.properties android/wenku-release.p12
mkdir -p "$repo/android"
install -m 600 "$temporary/android/wenku-release.p12" "$repo/android/wenku-release.p12"
install -m 600 "$temporary/android/key.properties" "$repo/android/key.properties"
echo "Android release signing restored."
