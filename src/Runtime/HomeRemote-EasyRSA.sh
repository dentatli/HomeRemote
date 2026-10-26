#!/bin/sh
# Launched with the EasyRSA directory as the working directory.
# EasyRSA ships mksh/Win32: its PATH separator is a semicolon.
export PATH="$PWD;$PWD/bin;$PATH"
export ENV="/disable-env"
export EASYRSA="$PWD"
export EASYRSA_PKI="$PWD/pki"
export EASYRSA_OPENSSL="$PWD/openssl.exe"
exec "$PWD/bin/sh.exe" "$PWD/easyrsa" "$@"
