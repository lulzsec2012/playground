#!/bin/bash

function add_clangd() {
  if [ ! -f .clangd ]; then
  # 写入配置文件
  cat > .clangd <<EOL
CompileFlags:
  CompilationDatabase: builds/debug_clang

InlayHints:
  BlockEnd: No
  Designators: Yes
  Enabled: Yes
  ParameterNames: No
  DeducedTypes: Yes
  TypeNameLimit: 24
EOL
  fi
}

HOME_PREFIX=~/.docker/home-work/
if [ -d $HOME_PREFIX ]; then
  echo "Out of docker"
else
  echo "In docker"
  HOME_PREFIX=~/
fi
HOME_PREFIX=$(realpath $HOME_PREFIX)
echo $HOME_PREFIX

pushd $HOME_PREFIX

mkdir -p work
pushd work

# Download hmcc
# export GIT_DISCOVERY_ACROSS_FILESYSTEM=1
git clone "ssh://lizhi.lu@gerrit.houmo.ai:29418/toolchain/hmcc" && scp -p -P 29418 lizhi.lu@gerrit.houmo.ai:hooks/commit-msg "hmcc/.git/hooks/"

pushd hmcc
#git submodule update --init --recursive -f
add_clangd
popd

popd

popd

pip install numpy onnx pybind11 pytest graphviz jinja2 matplotlib torch black
