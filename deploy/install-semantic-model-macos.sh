#!/usr/bin/env bash
set -euo pipefail

source_directory=${1:?usage: install-semantic-model-macos.sh /absolute/path/to/model-package}
remote=${MYNAS_REMOTE:-rbp@rsp}
key=${MYNAS_DEPLOY_KEY:-$HOME/.ssh/mynas_deploy}
model_id=qwen3-vl-embedding-2b
stamp=$(date -u +%Y%m%dT%H%M%SZ)
remote_stage="/tmp/mynas-model-$stamp"
remote_target="/mnt/nas/.mynas/models/$model_id"

ssh_options=(
  -i "$key"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o StrictHostKeyChecking=accept-new
  -o ProxyCommand=none
  -o ProxyJump=none
)

test -d "$source_directory" || { echo "Model package directory not found." >&2; exit 1; }
test -f "$key" || { echo "Deployment key not found." >&2; exit 1; }
command -v shasum >/dev/null || { echo "shasum is required." >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh is required." >&2; exit 1; }
command -v scp >/dev/null || { echo "scp is required." >&2; exit 1; }

verify_local() {
  cd "$source_directory"
  shasum -a 256 -c <<'EOF'
bf93391763c39cbd58242c4a3bd82603f87de5101d6d7add2cc9e735545096d1  config.json
fa4daabc7898d8712b7758eaae2964246e3d98978dd11fa101adacacc85a2561  embedding.mnn
ad701a1337151475006f296bf745e666cc5888f2052f57c564f91fc4aa644a00  embedding.mnn.json
b73a5f0a52b1949e6de8848f34fa6824b9279f59b21d0a1ac273680a5f4358c6  embedding.mnn.weight
4fb8fb0d5caa80362cd45e7a1f0d4608048bc2c94a8861179b4aa06ce21d9857  embeddings_int8.bin
04545bfe6d531d51e12a04426505b60dbb10e2bf4ab50815fc7313373963a168  llm_config.json
8a3c850cf8a04542812c857f83a7cc008de873b7bf66e065f96a0b822a911224  tokenizer.mtok
e30ea1d3fe4959681f0d06467f392883b37863c588e996ef8b317f0a772a6a1e  visual.mnn
f817346c4085c0b57d6df535e2ebc10e38b2f32656714a1da804ff106ab0f72e  visual.mnn.weight
EOF
}

echo "Verifying the local $model_id package…"
verify_local
echo "Uploading the verified model package…"
ssh "${ssh_options[@]}" "$remote" "set -eu; rm -rf '$remote_stage'; mkdir -p '$remote_stage'"
scp "${ssh_options[@]}" \
  "$source_directory"/{config.json,embedding.mnn,embedding.mnn.json,embedding.mnn.weight,embeddings_int8.bin,llm_config.json,tokenizer.mtok,visual.mnn,visual.mnn.weight} \
  "$remote:$remote_stage/"

echo "Verifying and activating the package on MyNAS…"
ssh "${ssh_options[@]}" "$remote" "set -eu; cd '$remote_stage'; sha256sum -c <<'EOF'
bf93391763c39cbd58242c4a3bd82603f87de5101d6d7add2cc9e735545096d1  config.json
fa4daabc7898d8712b7758eaae2964246e3d98978dd11fa101adacacc85a2561  embedding.mnn
ad701a1337151475006f296bf745e666cc5888f2052f57c564f91fc4aa644a00  embedding.mnn.json
b73a5f0a52b1949e6de8848f34fa6824b9279f59b21d0a1ac273680a5f4358c6  embedding.mnn.weight
4fb8fb0d5caa80362cd45e7a1f0d4608048bc2c94a8861179b4aa06ce21d9857  embeddings_int8.bin
04545bfe6d531d51e12a04426505b60dbb10e2bf4ab50815fc7313373963a168  llm_config.json
8a3c850cf8a04542812c857f83a7cc008de873b7bf66e065f96a0b822a911224  tokenizer.mtok
e30ea1d3fe4959681f0d06467f392883b37863c588e996ef8b317f0a772a6a1e  visual.mnn
f817346c4085c0b57d6df535e2ebc10e38b2f32656714a1da804ff106ab0f72e  visual.mnn.weight
EOF
sudo install -d -m 0700 /mnt/nas/.mynas/models
if test -e '$remote_target'; then sudo mv '$remote_target' '$remote_target.previous-$stamp'; fi
sudo mv '$remote_stage' '$remote_target'
sudo chown -R rbp:rbp '$remote_target'
sudo find '$remote_target' -type f -exec chmod 0600 {} +
"
echo "The $model_id package is ready on $remote."
