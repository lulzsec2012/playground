#!/bin/bash
# ============================================================================
# macOS Emacs 配置依赖自动安装脚本
# 适用于 lulzsec2012/emacs.d (https://github.com/lulzsec2012/emacs.d)
# 支持 macOS (Apple Silicon / Intel)
# ============================================================================
set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

# ── 配置 ──────────────────────────────────────────────────────────────────
EMACS_REPO="https://github.com/lulzsec2012/emacs.d"
EMACS_DIR="$HOME/.emacs.d"
PLANTUML_JAR_URL="https://github.com/plantuml/plantuml/releases/latest/download/plantuml.jar"
PLANTUML_JAR_PATH="$EMACS_DIR/plantuml.jar"

# ── Helper ────────────────────────────────────────────────────────────────
info()  { echo -e "${GREEN}  [INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $1"; }
error() { echo -e "${RED}  [ERROR]${NC} $1"; }
title() { echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"; }
step()  { echo -e "${CYAN}  >>>${NC} ${BOLD}$1${NC}"; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }

# ── 阶段控制 ──────────────────────────────────────────────────────────────
# 通过命令行参数跳过特定阶段: ./install-macos.sh --skip brew,fonts,emacs,clone
SKIP_STAGES=""
for arg in "$@"; do
  case "$arg" in
    --skip=*) SKIP_STAGES="${arg#--skip=}" ;;
    --help|-h)
      echo "Usage: $0 [--skip=brew,fonts,emacs,lsp,clone]"
      exit 0 ;;
  esac
done

skip_stage() {
  [[ ",$SKIP_STAGES," == *",$1,"* ]]
}

# ── 检测 CPU ──────────────────────────────────────────────────────────────
if [[ "$(uname -m)" == "arm64" ]]; then
  ARCH="arm64"
  HOMEBREW_PREFIX="/opt/homebrew"
else
  ARCH="x86_64"
  HOMEBREW_PREFIX="/usr/local"
fi

# ============================================================================
# Phase 0: Xcode Command Line Tools
# ============================================================================
phase_xcode() {
  title
  echo "${BOLD}  Phase 0: Xcode Command Line Tools${NC}"
  if xcode-select -p &>/dev/null; then
    ok "Xcode CLT already installed"
  else
    step "Installing Xcode Command Line Tools..."
    xcode-select --install || true
    warn "If a dialog appeared, complete the installation and re-run this script."
    exit 0
  fi
}

# ============================================================================
# Phase 1: Homebrew + 系统包
# ============================================================================
phase_brew() {
  title
  echo "${BOLD}  Phase 1: Homebrew & System Packages${NC}"

  # ── Homebrew ────────────────────────────────────────────────────────────
  if command -v brew &>/dev/null; then
    ok "Homebrew already installed"
  else
    step "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # 把 brew 加入 PATH
    if [[ "$ARCH" == "arm64" ]]; then
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
  fi

  # 确保 brew 在 PATH
  eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"

  # ── 更新 brew ──────────────────────────────────────────────────────────
  step "Updating Homebrew (may take a while)..."
  brew update --quiet

  # ── 核心工具 ────────────────────────────────────────────────────────────
  BREW_CORE=(
    git            # magit / vc
    ripgrep        # deadgrep / dumb-jump
    fd             # find-file-in-project
    fzf            # fussy / fzf-native
    jq             # jq-mode
    cmake          # project-cmake / vterm
    ninja          # build (dir-locals reference)
    libvterm       # emacs-libvterm
    coreutils      # basic system utils
    gnu-sed        # if needed by scripts
    enchant        # jinx spell-checker
  )

  step "Installing core tools..."
  for pkg in "${BREW_CORE[@]}"; do
    if brew list "$pkg" &>/dev/null 2>&1; then
      ok "$pkg already installed"
    else
      info "Installing $pkg..."
      brew install "$pkg"
    fi
  done

  # ── 可选工具（非关键） ──────────────────────────────────────────────────
  BREW_OPTIONAL=(
    graphviz        # graphviz-dot-mode
    pandoc          # document conversion
    imagemagick     # org-mode image generation
    clang-format    # clang-format config
  )
  for pkg in "${BREW_OPTIONAL[@]}"; do
    if brew list "$pkg" &>/dev/null 2>&1; then
      ok "$pkg already installed"
    else
      info "Installing $pkg..."
      brew install "$pkg" || warn "Failed to install $pkg (optional, continuing)"
    fi
  done
}

# ============================================================================
# Phase 2: Fonts
# ============================================================================
phase_fonts() {
  title
  echo "${BOLD}  Phase 2: Fonts${NC}"

  # ── Iosevka SS09 ────────────────────────────────────────────────────────
  if fc-list 2>/dev/null | grep -qi "Iosevka SS09"; then
    ok "Iosevka SS09 already installed"
  elif [[ -d "$HOME/Library/Fonts/IosevkaSS09" ]]; then
    ok "Iosevka SS09 already installed (manual)"
  else
    step "Installing Iosevka SS09 font..."
    # 从 homebrew cask-fonts 安装
    if ! brew tap | grep -q "homebrew/cask-fonts"; then
      brew tap homebrew/cask-fonts
    fi
    brew install --cask font-iosevka-ss09 || {
      warn "Brew cask not available, downloading manually..."
      FONT_VERSION="31.9.0"
      FONT_ZIP="/tmp/iosevka-ss09.zip"
      FONT_DIR="$HOME/Library/Fonts"
      curl -fsSL "https://github.com/be5invis/Iosevka/releases/download/v${FONT_VERSION}/SuperTTC-IosevkaSS09-${FONT_VERSION}.zip" \
        -o "$FONT_ZIP"
      unzip -qo "$FONT_ZIP" -d /tmp/iosevka-ss09/
      cp /tmp/iosevka-ss09/*.ttc "$FONT_DIR/" 2>/dev/null || true
      rm -rf /tmp/iosevka-ss09 "$FONT_ZIP"
    }
    ok "Iosevka SS09 installed"
  fi

  # ── Ubuntu Mono (选项, 在 Linux 端默认) ─────────────────────────────────
  info "Optional: Ubuntu Mono font (only needed if you switch to Linux default)"
  brew install --cask font-ubuntu-mono 2>/dev/null || true
}

# ============================================================================
# Phase 3: Emacs
# ============================================================================
phase_emacs() {
  title
  echo "${BOLD}  Phase 3: Emacs (with native-comp)${NC}"

  if command -v emacs &>/dev/null; then
    EMACS_VER=$(emacs --version | head -1 | grep -oP '[\d]+\.[\d]+' | head -1)
    ok "Emacs already installed (version $EMACS_VER)"
    # 检查是否 native-comp 启用
    if emacs -Q --batch --eval '(message "%s" (if (native-comp-available-p) "YES" "NO"))' 2>&1 | grep -q YES; then
      ok "Native-comp is enabled"
    else
      warn "Native-comp is NOT enabled. Consider reinstalling with emacs-plus or emacs-mac."
    fi
    return
  fi

  step "Installing Emacs with native-comp support..."

  # 优先选择 emacs-plus (支持 native-comp, 且维护活跃)
  # 备选: emacs-mac (https://github.com/railwaycat/homebrew-emacsmacport)
  if brew tap | grep -q "d12frosted/emacs-plus"; then
    ok "d12frosted/emacs-plus tap already added"
  else
    brew tap d12frosted/emacs-plus
  fi

  # 检测最新的 emacs-plus 版本
  EMACS_FORMULA="emacs-plus"
  info "Installing $EMACS_FORMULA (this will take a while to compile)..."
  brew install "$EMACS_FORMULA" --with-native-comp || {
    warn "emacs-plus failed to install. Trying emacs-mac (alternative)..."
    brew tap railwaycat/emacsmacport
    brew install emacs-mac --with-native-comp || {
      error "Failed to install Emacs. Try manually: brew install emacs"
      exit 1
    }
  }

  # 链接到 Applications
  if [[ -d "$HOMEBREW_PREFIX/opt/emacs-plus" ]]; then
    osascript -e 'tell application "Finder" to make alias file to POSIX file "'"$HOMEBREW_PREFIX"'/opt/emacs-plus/Emacs.app" at POSIX file "'"$HOME"'/Applications"' 2>/dev/null || true
  fi

  ok "Emacs installed"
}

# ============================================================================
# Phase 4: LSP Servers
# ============================================================================
phase_lsp() {
  title
  echo "${BOLD}  Phase 4: LSP Servers${NC}"

  # ── clangd (via llvm) ──────────────────────────────────────────────────
  if ! command -v clangd &>/dev/null; then
    step "Installing clangd (via llvm)..."
    brew install llvm
    # 将 llvm 的 clangd 加入 PATH
    if [[ "$ARCH" == "arm64" ]]; then
      LLVM_PATH="/opt/homebrew/opt/llvm/bin"
    else
      LLVM_PATH="/usr/local/opt/llvm/bin"
    fi
    if [[ -d "$LLVM_PATH" ]]; then
      info "Add to your .zshrc: export PATH=\"$LLVM_PATH:\$PATH\""
      # 自动写入 .zshrc 如果需要
      grep -q "$LLVM_PATH" "$HOME/.zshrc" 2>/dev/null || \
        echo "export PATH=\"$LLVM_PATH:\$PATH\"  # llvm/clangd for emacs eglot" >> "$HOME/.zshrc"
    fi
  else
    ok "clangd already installed"
  fi

  # ── texlab ──────────────────────────────────────────────────────────────
  if ! command -v texlab &>/dev/null; then
    step "Installing texlab..."
    brew install texlab
  else
    ok "texlab already installed"
  fi

  # ── bash-language-server ────────────────────────────────────────────────
  if ! command -v bash-language-server &>/dev/null; then
    step "Installing bash-language-server..."
    brew install bash-language-server
  else
    ok "bash-language-server already installed"
  fi

  # ── yaml-language-server ────────────────────────────────────────────────
  if ! command -v yaml-language-server &>/dev/null; then
    step "Installing yaml-language-server..."
    brew install yaml-language-server
  else
    ok "yaml-language-server already installed"
  fi

  # ── dockerfile-language-server ──────────────────────────────────────────
  if ! command -v docker-langserver &>/dev/null; then
    step "Installing dockerfile-language-server..."
    brew install dockerfile-language-server
  else
    ok "dockerfile-language-server already installed"
  fi

  # ── Node.js (typescript-language-server 依赖) ───────────────────────────
  if ! command -v node &>/dev/null; then
    step "Installing Node.js..."
    brew install node
  else
    ok "Node.js already installed ($(node --version))"
  fi

  # ── typescript-language-server ─────────────────────────────────────────
  if ! npm list -g typescript-language-server &>/dev/null 2>&1; then
    step "Installing typescript-language-server (npm global)..."
    npm install -g typescript-language-server
  else
    ok "typescript-language-server already installed"
  fi

  # ── Rust + rust-analyzer ────────────────────────────────────────────────
  if ! command -v rustup &>/dev/null; then
    step "Installing Rust (rustup)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    source "$HOME/.cargo/env"
    rustup component add rust-analyzer
  else
    ok "Rust already installed ($(rustc --version))"
    if ! command -v rust-analyzer &>/dev/null; then
      step "Adding rust-analyzer component..."
      rustup component add rust-analyzer
    else
      ok "rust-analyzer already installed"
    fi
  fi

  # ── Python 工具 ─────────────────────────────────────────────────────────
  if ! command -v pyright &>/dev/null && ! command -v ty &>/dev/null; then
    step "Installing Python type checker for eglot..."
    # 配置使用 "ty" server, 优先安装 pyright 作为 fallback
    pip3 install pyright --user 2>/dev/null || warn "Could not install pyright (non-critical)"
  fi
  if ! command -v ruff &>/dev/null; then
    step "Installing ruff (linter/formatter)..."
    pip3 install ruff --user 2>/dev/null || warn "Could not install ruff (non-critical)"
  fi
}

# ============================================================================
# Phase 5: LaTeX (texlive)
# ============================================================================
phase_texlive() {
  title
  echo "${BOLD}  Phase 5: LaTeX Distribution (texlive)${NC}"

  if command -v pdflatex &>/dev/null; then
    ok "TeX Live already installed"
    return
  fi

  step "Installing TeX Live (basic)..."
  warn "This is a large download (~1GB)."
  warn "Skip with: $0 --skip=texlive"

  if skip_stage "texlive"; then
    info "Skipping TeX Live installation"
    return
  fi

  # macOS 推荐 MacTeX。但太大了，使用 basic 方案
  if [[ "$ARCH" == "arm64" ]]; then
    brew install --cask mactex-no-gui || {
      warn "MacTeX installation failed or cancelled. Skipping."
      warn "Install manually from: https://tug.org/mactex/"
    }
  else
    brew install --cask mactex-no-gui || {
      warn "MacTeX installation failed or cancelled. Skipping."
    }
  fi

  # 添加 texbin 到 PATH (这是配置中 macOS PATH 的一部分)
  TEXBIN="/Library/TeX/texbin"
  if [[ -d "$TEXBIN" ]]; then
    grep -q "$TEXBIN" "$HOME/.zshrc" 2>/dev/null || \
      echo "export PATH=\"$TEXBIN:\$PATH\"  # TeX Live" >> "$HOME/.zshrc"
  fi
}

# ============================================================================
# Phase 6: PlantUML
# ============================================================================
phase_plantuml() {
  title
  echo "${BOLD}  Phase 6: PlantUML${NC}"

  if [[ -f "$PLANTUML_JAR_PATH" ]]; then
    ok "PlantUML jar exists at $PLANTUML_JAR_PATH"
    return
  fi

  step "Downloading PlantUML..."
  # 配置中设置 plantuml-default-exec-mode 为 'jar，需要 java
  if ! command -v java &>/dev/null; then
    step "Installing Java (OpenJDK) for PlantUML..."
    brew install openjdk
  else
    ok "Java already installed"
  fi

  curl -fsSL "$PLANTUML_JAR_URL" -o "$PLANTUML_JAR_PATH" || {
    warn "Failed to download PlantUML jar. Install manually."
  }
  if [[ -f "$PLANTUML_JAR_PATH" ]]; then
    ok "PlantUML jar downloaded to $PLANTUML_JAR_PATH"
  fi
}

# ============================================================================
# Phase 7: Clone Emacs 配置
# ============================================================================
phase_clone() {
  title
  echo "${BOLD}  Phase 7: Clone emacs.d${NC}"

  if [[ -d "$EMACS_DIR" ]]; then
    if [[ -d "$EMACS_DIR/.git" ]]; then
      REPO_URL=$(git -C "$EMACS_DIR" remote get-url origin 2>/dev/null || echo "unknown")
      if [[ "$REPO_URL" == *"lulzsec2012/emacs.d"* ]]; then
        ok "emacs.d already cloned from lulzsec2012/emacs.d"
        step "Updating submodules..."
        git -C "$EMACS_DIR" submodule update --init --recursive
        return
      else
        warn "$EMACS_DIR exists but is from a different repo ($REPO_URL)"
        warn "Backing up to ${EMACS_DIR}.bak"
        mv "$EMACS_DIR" "${EMACS_DIR}.bak"
      fi
    else
      warn "$EMACS_DIR exists but is not a git repo"
      warn "Backing up to ${EMACS_DIR}.bak"
      mv "$EMACS_DIR" "${EMACS_DIR}.bak"
    fi
  fi

  step "Cloning lulzsec2012/emacs.d to $EMACS_DIR..."
  git clone --recursive "$EMACS_REPO" "$EMACS_DIR"

  # ── 验证 fuz.el Rust 动态模块 ────────────────────────────────────
  if command -v cargo &>/dev/null && [[ -f "$EMACS_DIR/third_party/fuz.el/Cargo.toml" ]]; then
    step "Verifying fuz Rust module compiles..."
    (cd "$EMACS_DIR/third_party/fuz.el" && cargo build --release 2>/dev/null)
    if [[ $? -eq 0 ]]; then
      ok "fuz module compiles successfully"
      # 创建符号链接供 Emacs 加载
      ln -sf "$EMACS_DIR/third_party/fuz.el/target/release/libfuz_core.dylib" \
             "$EMACS_DIR/third_party/fuz.el/fuz-core.so"
    else
      warn "fuz cargo build failed — checking for Homebrew library issues..."
      # Homebrew libgit2 可能依赖过期的 llhttp 版本
      if otool -L /opt/homebrew/Cellar/libgit2/*/lib/libgit2*.dylib 2>/dev/null | grep -q "llhttp\.9\.3"; then
        warn "Fixing Homebrew libgit2/llhttp compatibility..."
        LLLIB=$(ls /opt/homebrew/Cellar/llhttp/*/lib/libllhttp*.dylib 2>/dev/null | grep -v "9\.3" | head -1)
        [[ -n "$LLLIB" ]] && ln -sf "$LLLIB" "$(dirname "$LLLIB")/libllhttp.9.3.dylib"
        (cd "$EMACS_DIR/third_party/fuz.el" && cargo build --release) && \
          ok "fuz module rebuilt successfully after fix" || \
          error "fuz module still fails — check 'cargo build --release' in third_party/fuz.el"
      else
        error "fuz cargo build failed — check 'cargo build --release' in third_party/fuz.el"
      fi
    fi
  fi

  ok "Configuration cloned. Submodules initialized."
}

# ============================================================================
# Phase 8: 首次启动安装 Emacs 包
# ============================================================================
phase_packages() {
  title
  echo "${BOLD}  Phase 8: Install Emacs Packages (first run)${NC}"

  if ! command -v emacs &>/dev/null; then
    warn "Emacs not yet installed. Run phase_emacs first."
    return
  fi

  if [[ ! -f "$EMACS_DIR/init.el" ]]; then
    warn "Configuration not found at $EMACS_DIR. Run phase_clone first."
    return
  fi

  step "Running Emacs headless to install packages (this may take a while)..."
  warn "This will run emacs --batch to auto-install all use-package dependencies."
  warn "Any errors will be shown below."

  # 清理 stale eln cache 避免 native-comp 冲突
  rm -rf "$HOME/.emacs.d/eln-cache/" 2>/dev/null || true

  # 执行 emacs --batch，第一次运行会触发 use-package 自动安装
  if emacs --batch --load "$EMACS_DIR/init.el" \
    --eval '(message "=== Package installation complete ===")' 2>&1; then
    ok "Emacs packages installed successfully"
  else
    warn "Some packages may have failed to install."
    warn "Run 'emacs' (interactively) to complete installation."
    warn "First launch warnings are normal."
  fi
}

# ============================================================================
# 后置信息
# ============================================================================
show_summary() {
  title
  echo "${BOLD}  Installation Summary${NC}"
  echo ""

  check() {
    local cmd="$1" name="${2:-$1}"
    if command -v "$cmd" &>/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} $name"
    else
      echo -e "  ${RED}✗${NC} $name"
    fi
  }

  check git
  check rg "ripgrep (rg)"
  check fd "fd"
  check fzf
  check jq
  check cmake
  check ninja
  check clangd
  check texlab
  check bash-language-server
  check yaml-language-server
  check docker-langserver
  check node "Node.js"
  check rustc "Rust"
  check rust-analyzer
  check emacs "Emacs"
  check java "Java (PlantUML)"

  if [[ -f "$PLANTUML_JAR_PATH" ]]; then
    echo -e "  ${GREEN}✓${NC} PlantUML jar"
  else
    echo -e "  ${RED}✗${NC} PlantUML jar"
  fi

  if fc-list 2>/dev/null | grep -qi "Iosevka SS09" || [[ -d "$HOME/Library/Fonts/IosevkaSS09" ]]; then
    echo -e "  ${GREEN}✓${NC} Iosevka SS09 Font"
  else
    echo -e "  ${RED}✗${NC} Iosevka SS09 Font"
  fi

  echo ""
  echo "  ${BOLD}Post-install steps:${NC}"
  echo "  1. Ensure $HOMEBREW_PREFIX/opt/llvm/bin is in your PATH"
  echo "  2. Open Emacs and let it finish installing packages"
  echo "  3. Optionally: M-x all-the-icons-install-fonts (if using icon packages)"
  echo "  4. Restart Emacs for all settings to take effect"
  echo ""
  echo "  ${BOLD}Notes:${NC}"
  echo "  - The config has tree-sitter disabled on macOS (it uses regular major modes)"
  echo "  - beardbolt (assembly viewer) is Linux-only in this config"
  echo "  - Font Iosevka SS09 is expected — you can change it in configuration.org"
  echo "    line ~411: (setq my/default-font ...)"
  echo ""
}

# ============================================================================
# Main
# ============================================================================
main() {
  echo ""
  echo "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo "${BOLD}║      macOS Emacs Dependency Installer (lulzsec2012/emacs.d)   ║${NC}"
  echo "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo "  Architecture: $ARCH"
  echo ""

  phase_xcode

  if ! skip_stage "brew";    then phase_brew;    fi
  if ! skip_stage "fonts";   then phase_fonts;   fi
  if ! skip_stage "emacs";   then phase_emacs;   fi
  if ! skip_stage "lsp";     then phase_lsp;     fi
  if ! skip_stage "texlive"; then phase_texlive; fi
  if ! skip_stage "plantuml";then phase_plantuml; fi
  if ! skip_stage "clone";   then phase_clone;   fi
  if ! skip_stage "packages";then phase_packages; fi

  show_summary

  title
  echo "${BOLD}  Done!${NC}"
  echo ""
  echo "  Open Emacs and enjoy 🚀"
  echo ""
}

main "$@"
