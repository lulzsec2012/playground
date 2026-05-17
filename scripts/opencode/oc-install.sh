#!/usr/bin/env bash
set -e

echo "========================================"
echo "  OpenCode Environment Setup"
echo "========================================"

# ---------- helpers ----------

# npm 包版本检测：未安装则安装，已安装则对比 registry 版本决定升级/跳过
npm_check_upgrade() {
  local pkg="$1"
  local label="${2:-$pkg}"
  local installed

  installed=$(npm ls -g --depth=0 "$pkg" 2>&1 | grep -Eo "@[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?" | head -1 | tr -d '@')
  if [ -z "$installed" ]; then
    echo "  $label 未安装，正在安装..."
    npm_install_or_sudo "$pkg" || { echo "  $label 安装失败" >&2; return 1; }
    return
  fi

  local latest
  latest=$(npm view "$pkg" version 2>/dev/null || echo "")
  if [ -z "$latest" ]; then
    echo "  $label $installed（无法获取最新版本）"
    return
  fi

  if [ "$installed" = "$latest" ]; then
    echo "  $label $installed（已是最新），跳过"
  else
    echo "  $label: $installed -> $latest，升级中..."
    npm_install_or_sudo "$pkg" || { echo "  $label 升级失败" >&2; return 1; }
  fi
}

npm_install_or_sudo() {
  local pkg="$1"
  if npm install -g "$pkg" 2>/dev/null; then
    return 0
  fi
  echo "  /usr/local 无写入权限，使用 sudo 安装..."
  sudo npm install -g "$pkg"
}

ver_gt() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]
}

# ---------- 1. opencode CLI ----------
echo ""
echo "[1/7] Installing opencode CLI..."
npm_install_opencode() {
  npm_install_or_sudo "opencode-ai"
}

if command -v opencode &>/dev/null; then
  inst_ver=$(opencode --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?' | head -1)
  if [ -z "$inst_ver" ]; then
    echo "  opencode 已安装（版本号未识别）"
  else
    latest_ver=$(npm view opencode-ai version 2>/dev/null || echo "")
    if [ -z "$latest_ver" ]; then
      echo "  opencode $inst_ver（无法获取最新版本）"
    elif [ "$inst_ver" = "$latest_ver" ]; then
      echo "  opencode $inst_ver（已是最新），跳过"
    elif ver_gt "$latest_ver" "$inst_ver"; then
      echo "  opencode: $inst_ver -> $latest_ver，升级中..."
      npm_install_opencode
      echo "  opencode 已升级: $(opencode --version)"
    else
      echo "  opencode $inst_ver（已是最新），跳过"
    fi
  fi
else
  echo "  通过 npm 安装 opencode-ai..."
  if command -v npm &>/dev/null; then
    npm_install_opencode
    echo "  opencode installed: $(opencode --version)"
  else
    echo "  尝试官方脚本安装..."
    if curl -fsSL --connect-timeout 5 --max-time 15 https://opencode.ai/install | bash; then
      export PATH="$HOME/.opencode/bin:$PATH"
      echo "  opencode installed: $(opencode --version)"
    else
      echo "  npm 和官方脚本均不可用，请手动安装 opencode" >&2
      exit 1
    fi
  fi
fi

# ---------- 2. bun ----------
echo ""
echo "[2/7] Installing bun..."
_has_bun=false
if command -v bun &>/dev/null; then
  _has_bun=true
elif [ -f "$HOME/.bun/bin/bun" ]; then
  export PATH="$HOME/.bun/bin:$PATH"
  _has_bun=true
fi

if $_has_bun; then
  inst_ver=$(bun --version)
  echo "  bun $inst_ver，检测升级..."
  _old_ver="$inst_ver"
  bun upgrade 2>/dev/null || echo "  (bun upgrade 不可用，跳过)"
  _new_ver=$(bun --version)
  if [ "$_old_ver" != "$_new_ver" ]; then
    echo "  bun 已升级: $_old_ver -> $_new_ver"
  else
    echo "  bun $inst_ver（已是最新），跳过"
  fi
else
  echo "  Installing bun..."
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
  echo "  bun installed: $(bun --version)"
fi

# ---------- 3. oh-my-opencode ----------
echo ""
echo "[3/7] Installing oh-my-opencode plugin..."
npm_check_upgrade "oh-my-opencode"
echo "  配置指南: https://raw.githubusercontent.com/code-yeongyu/oh-my-opencode/refs/heads/master/docs/guide/installation.md"

# ---------- 4. openspec ----------
echo ""
echo "[4/7] Installing openspec..."
npm_check_upgrade "@fission-ai/openspec" "openspec"
echo "  在项目目录执行 'openspec init' 初始化"

# 清理 npx 输出中的 ANSI 控制字符和进度条
clean_npx() {
  sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][0-9;]*[^\x1b]*\x1b\\//g; s/\r//g' 2>/dev/null || cat
}

skill_dir() {
  local d="$HOME/.agents/skills/$1"
  [ -d "$d" ] && echo "$d" && return 0
  d="$HOME/.opencode/skills/$1"
  [ -d "$d" ] && echo "$d" && return 0
  return 1
}

# ---------- 5. superpowers ----------
echo ""
echo "[5/7] Installing superpowers skills..."
if skill_dir "superpowers" >/dev/null; then
  echo "  superpowers 已安装，检查更新..."
  npx --yes skills add obra/superpowers 2>&1 | clean_npx
else
  npx --yes skills add obra/superpowers
  echo "  superpowers installed"
fi

# ---------- 6. planning-with-files ----------
echo ""
echo "[6/7] Installing planning-with-files..."
if skill_dir "planning-with-files" >/dev/null; then
  echo "  planning-with-files 已安装，检查更新..."
  npx --yes skills add OthmanAdi/planning-with-files 2>&1 | clean_npx
else
  npx --yes skills add OthmanAdi/planning-with-files
  echo "  planning-with-files installed"
fi

# ---------- 7. conversation-analysis ----------
echo ""
echo "[7/7] Installing opencode-conversation-analysis..."
if skill_dir "opencode-conversation-analysis" >/dev/null; then
  echo "  opencode-conversation-analysis 已安装，检查更新..."
  npx --yes skills add connorads/dotfiles@opencode-conversation-analysis -y -g 2>&1 | clean_npx || echo "  跳过"
else
  npx --yes skills add connorads/dotfiles@opencode-conversation-analysis -y -g || echo "  ⚠️ 跳过"
fi

# ---------- extra tools ----------
echo ""
echo "--- Optional tools ---"

echo ""
echo "opencode-agent-optimizer:"
npm_check_upgrade "opencode-agent-optimizer"
echo "  用法: opencode-agent-optimizer summary"
echo "        opencode-agent-optimizer suggest --all"
echo "        opencode-agent-optimizer install"

echo ""
echo "opencode-analytics:"
npm_check_upgrade "opencode-analytics"
echo "  注意: opencode-analytics v0.1.0 为库文件，无 CLI 命令"
echo "  用法: 在项目中 import 使用"

echo ""
echo "opencode-multi:"
ensure_rust() {
  if command -v cargo &>/dev/null && [ "$(cargo --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+' | head -1)" = "1.8" ]; then
    echo "  Rust $(cargo --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+') OK"
    return 0
  fi
  if command -v rustup &>/dev/null; then
    echo "  升级 Rust..."
    rustup default stable 2>&1 | tail -1
    . "$HOME/.cargo/env"
    return 0
  fi
  echo "  安装 rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tail -1
  . "$HOME/.cargo/env"
}
ensure_rust
if command -v cargo &>/dev/null; then
  local_ver=$(cargo install --list 2>/dev/null | grep -E '^opencode-multi v' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  latest_ver=$(cargo search opencode-multi 2>/dev/null | grep -Eo '^opencode-multi[^#]*#([0-9]+\.[0-9]+\.[0-9]+)' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$local_ver" ] && [ "$local_ver" = "$latest_ver" ]; then
    echo "  opencode-multi $local_ver（已是最新），跳过"
  elif [ -n "$local_ver" ]; then
    echo "  opencode-multi: $local_ver -> $latest_ver，升级中..."
    cargo install opencode-multi --force 2>&1 | tail -1
  else
    echo "  安装 opencode-multi..."
    cargo install opencode-multi 2>&1 | tail -1
  fi
else
  echo "  cargo 不可用，跳过 opencode-multi"
fi

echo ""
echo "========================================"
echo "  OpenCode Environment Setup Complete!"
echo "========================================"
echo ""
echo "下一步:"
echo "  1. 配置 opencode.json (复制 ~/.config/opencode/opencode.json)"
echo "  2. source ~/.bashrc 或新开终端"
echo "  3. 运行 opencode 开始使用"
