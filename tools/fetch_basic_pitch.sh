#!/bin/sh
# Spotify basic-pitch (Apache-2.0) ships a Core ML model inside its wheel.
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
curl -sSLo "$tmp/bp.whl" https://files.pythonhosted.org/packages/99/0e/3a36d22562daeb0ae3c78ac78da3f8dba96543c5576ed57d4acb8ddbab5b/basic_pitch-0.4.0-py2.py3-none-any.whl
unzip -q "$tmp/bp.whl" 'basic_pitch/saved_models/icassp_2022/nmp.mlpackage/*' -d "$tmp"
mkdir -p Models
rm -rf Models/basic-pitch.mlpackage
cp -R "$tmp/basic_pitch/saved_models/icassp_2022/nmp.mlpackage" Models/basic-pitch.mlpackage
rm -rf "$tmp"
echo "Models/basic-pitch.mlpackage"
