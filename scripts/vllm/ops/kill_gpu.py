#!/usr/bin/env python3
"""kill_gpu.py — 精准释放指定 GPU / 端口上的 vLLM 进程

特性:
  - 通过 /proc/PID/environ 的 CUDA_VISIBLE_DEVICES 定位 GPU 进程
  - 通过 nvidia-smi 检测 zombie PID（进程已死但 VRAM 未释放）
  - 支持 --all 一键清理所有 GPU 进程
  - 支持 --zombie 清理 zombie GPU 上下文
  - 命令行 & Python import 双模式

用法（CLI）:
    python kill_gpu.py --gpus 0,1,2,3        # 释放 GPU 0-3
    python kill_gpu.py --gpus 4-7            # 释放 GPU 4-7
    python kill_gpu.py --port 8002           # 释放端口 8002
    python kill_gpu.py --all                 # 释放所有 GPU
    python kill_gpu.py --status              # GPU 进程映射
    python kill_gpu.py --zombie              # 清理 zombie GPU 上下文

用法（Python API）:
    from kill_gpu import kill_gpus, kill_port, gpu_status, clear_zombies

    kill_gpus("0,1,2,3")    # 释放指定 GPU
    kill_port(8002)         # 释放端口
    clear_zombies([0,1,2,3]) # 清理 zombie GPU
"""

import os
import re
import subprocess
import signal
import time
from typing import Optional


def _uid() -> int:
    return os.getuid()


def _get_cvd(pid: int) -> Optional[str]:
    """读取进程的 CUDA_VISIBLE_DEVICES 环境变量"""
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            for item in f.read().split(b"\0"):
                if item.startswith(b"CUDA_VISIBLE_DEVICES="):
                    val = item.decode().split("=", 1)[1]
                    return val if val else None  # 空字符串视为未设置
    except (OSError, PermissionError):
        pass
    return None


def _kill_pid(pid: int, sig: int = signal.SIGKILL) -> bool:
    try:
        os.kill(pid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _expand_gpus(gpu_str: str) -> set[int]:
    """解析 GPU 字符串: '0,1,4-7' → {0,1,4,5,6,7}"""
    result = set()
    for part in gpu_str.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            if "-" in part and part != "-":
                a, b = part.split("-", 1)
                if a and b:
                    result.update(range(int(a), int(b) + 1))
            elif part.isdigit() or (part.startswith("-") and part[1:].isdigit()):
                result.add(int(part))
        except (ValueError, IndexError):
            continue
    return result


def _find_procs_on_gpus(target_gpus: set[int]) -> dict[int, set[int]]:
    """查找使用目标 GPU 的进程，返回 {pid: used_gpu_set}"""
    me = _uid()
    result = {}

    for pid_dir in os.listdir("/proc"):
        if not pid_dir.isdigit():
            continue
        pid = int(pid_dir)

        try:
            stat = os.stat(f"/proc/{pid}")
        except OSError:
            continue
        if stat.st_uid != me:
            continue

        cvd = _get_cvd(pid)
        if cvd is None:
            continue

        pgpus = _expand_gpus(cvd)
        if not pgpus:
            # CUDA_VISIBLE_DEVICES 为空 → 无法确定 GPU，跳过（宁可不杀，不可错杀）
            # 注意：vLLM worker 若未继承 cvd 也会在此跳过，避免误伤其他实例
            continue

        overlap = pgpus & target_gpus
        if overlap:
            result[pid] = overlap

            # 子进程仅在父进程命中目标 GPU 时一并处理（防止误杀其他实例的 worker）
            try:
                with open(f"/proc/{pid}/task/{pid}/children") as f:
                    for child_pid in f.read().strip().split():
                        if child_pid:
                            cp = int(child_pid)
                            try:
                                if os.stat(f"/proc/{cp}").st_uid == me:
                                    result[cp] = overlap
                            except OSError:
                                pass
            except OSError:
                pass

    return result


def _get_nvidia_smi_zombies() -> list[tuple[int, str, int]]:
    """返回 nvidia-smi 中的 zombie PID 列表 [(pid, gpu_bus_id, memory_mb), ...]

    zombie = nvidia-smi 报告了该 PID 占用 GPU 内存，但 /proc/PID 不存在。
    这是 NVIDIA 驱动的已知问题：进程异常退出后 CUDA context 未释放。
    """
    zombies = []
    try:
        proc = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid,gpu_bus_id,used_memory",
             "--format=csv,noheader"],
            capture_output=True, text=True, timeout=10
        )
        for line in proc.stdout.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 3:
                continue
            try:
                pid = int(parts[0])
            except ValueError:
                continue

            # zombie = PID 不存在于 /proc
            if not os.path.exists(f"/proc/{pid}"):
                mem = int(parts[2].split()[0])
                gpu_bus = parts[1].strip()
                # 从 bus ID 提取 GPU index
                gpu_idx = _bus_to_gpu_index(gpu_bus)
                zombies.append((pid, gpu_idx, mem))

    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    return zombies


def _bus_to_gpu_index(bus_id: str) -> int:
    """将 nvidia-smi bus ID 映射到 GPU index (通过 cuda-visible order)"""
    try:
        proc = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,uuid,pci.bus_id",
             "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5
        )
        for line in proc.stdout.strip().split("\n"):
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 3:
                idx = int(parts[0].strip())
                bus = parts[2].strip()
                if bus in bus_id or bus_id in bus:
                    return idx
    except Exception:
        pass
    return -1


# ── Public API ──────────────────────────────────────────────────────────

def kill_gpus(gpu_list: str, sig: int = signal.SIGKILL) -> int:
    """释放指定 GPU 上的所有进程，返回杀掉的进程数。

    gpu_list: "0,1" 或 "4-7" 或 "0,1,4-7"
    """
    targets = _expand_gpus(gpu_list)
    if not targets:
        return 0

    procs = _find_procs_on_gpus(targets)
    count = 0

    for pid in list(procs.keys()):
        _kill_pid(pid, signal.SIGTERM if sig == signal.SIGKILL else sig)
        count += 1

    if sig == signal.SIGKILL and procs:
        time.sleep(2)
        for pid in list(procs.keys()):
            try:
                os.kill(pid, 0)
                _kill_pid(pid, signal.SIGKILL)
            except OSError:
                pass

    return count


def kill_port(port: int) -> int:
    """释放占用指定端口的进程，返回杀掉的进程数"""
    count = 0

    # 方法 1: ss/lsof
    for cmd in [["ss", "-tlnp"], ["fuser", f"{port}/tcp"]]:
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            for pid_str in re.findall(r'[Pp][Ii][Dd][= ]*(\d+)', result.stdout):
                if pid_str.isdigit() and _kill_pid(int(pid_str)):
                    count += 1
            if count > 0:
                return count
        except (subprocess.TimeoutExpired, FileNotFoundError):
            continue

    # 方法 2: /proc/net/tcp
    port_hex = f"{port:04X}"
    try:
        with open("/proc/net/tcp") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 10 and f":{port_hex}" in parts[1]:
                    inode = parts[9]
                    for pid_dir in os.listdir("/proc"):
                        if not pid_dir.isdigit():
                            continue
                        try:
                            for fd in os.listdir(f"/proc/{pid_dir}/fd"):
                                link = os.readlink(f"/proc/{pid_dir}/fd/{fd}")
                                if f"socket:[{inode}]" in link:
                                    _kill_pid(int(pid_dir))
                                    count += 1
                        except OSError:
                            continue
    except OSError:
        pass

    return count


def kill_all_gpus() -> int:
    """释放所有 GPU 上的进程"""
    # 获取所有 GPU index
    try:
        result = subprocess.run(
            ["nvidia-smi", "-L"], capture_output=True, text=True, timeout=5
        )
        gpu_count = len(result.stdout.strip().split("\n"))
    except Exception:
        gpu_count = 8

    return kill_gpus(",".join(str(i) for i in range(gpu_count)))


def clear_zombies(target_gpus: Optional[set[int]] = None) -> int:
    """清理 zombie GPU 上下文 (nvidia-smi 中进程已死但 VRAM 未释放)。

    注意: 清理 zombie 需要 root 权限调用 nvidia-smi -r 重置 GPU。
    无 root 时仅报告 zombie 信息。
    """
    zombies = _get_nvidia_smi_zombies()
    count = 0

    if not zombies:
        return 0

    for pid, gpu_idx, mem in zombies:
        if target_gpus is not None and gpu_idx not in target_gpus:
            continue
        print(f"  🧟 zombie PID={pid} GPU={gpu_idx} VRAM={mem}MiB")

        # 尝试 GPU reset
        if target_gpus is not None:
            try:
                subprocess.run(
                    ["sudo", "nvidia-smi", "drain", "-p", str(gpu_idx), "-m", "1"],
                    capture_output=True, timeout=10
                )
                subprocess.run(
                    ["sudo", "nvidia-smi", "drain", "-p", str(gpu_idx), "-m", "0"],
                    capture_output=True, timeout=10
                )
                count += 1
            except Exception:
                pass

    if count == 0 and zombies:
        print("  ⚠️  无 root 权限，无法重置 GPU。zombie VRAM 将在下次重启后释放。")
        print("     可尝试: sudo nvidia-smi drain -p <GPU> -m 1 && sudo nvidia-smi drain -p <GPU> -m 0")

    return count


def gpu_status():
    """打印 GPU → 进程 映射"""
    print()
    print(f"=== GPU 进程映射 (用户: {os.environ.get('USER', '?')}) ===")
    print(f"{'PID':<12} {'GPUs':<12} {'进程'}")
    print(f"{'─'*3:<12} {'─'*4:<12} {'─'*4}")

    shown = set()
    me = _uid()

    for pid_dir in sorted(os.listdir("/proc"), key=lambda x: int(x) if x.isdigit() else 0):
        if not pid_dir.isdigit():
            continue
        pid = int(pid_dir)
        if pid in shown:
            continue
        try:
            if os.stat(f"/proc/{pid}").st_uid != me:
                continue
        except OSError:
            continue

        cvd = _get_cvd(pid)
        if cvd is None:
            continue

        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode(errors="replace")[:80]
        except OSError:
            cmd = "?"

        shown.add(pid)
        print(f"  {pid:<12} {cvd:<12} {cmd}")

    # Zombie 警告
    zombies = _get_nvidia_smi_zombies()
    if zombies:
        print(f"\n  🧟 Zombie GPU 上下文 (进程已死但 VRAM 未释放):")
        for pid, gpu_idx, mem in zombies:
            print(f"     PID={pid} GPU={gpu_idx} VRAM={mem}MiB")

    print()
    subprocess.run(
        ["nvidia-smi", "--query-gpu=index,memory.used,memory.total",
         "--format=csv,noheader"], timeout=10
    )
    print()


# ── CLI ─────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse
    import sys
    p = argparse.ArgumentParser(description="GPU 进程清理工具")
    p.add_argument("--gpus", help="目标 GPU 列表 (e.g. 0,1 或 4-7)")
    p.add_argument("--port", type=int, help="目标端口")
    p.add_argument("--status", action="store_true", help="查看状态")
    p.add_argument("--all", dest="kill_all", action="store_true", help="释放所有 GPU")
    p.add_argument("--zombie", action="store_true", help="清理 zombie GPU 上下文")
    p.add_argument("--force", "-9", dest="_sig9", action="store_true", help="使用 SIGKILL (默认)")
    args = p.parse_args()

    if args.status:
        gpu_status()
        sys.exit(0)

    if args.zombie:
        targets = _expand_gpus(args.gpus) if args.gpus else None
        n = clear_zombies(targets)
        sys.exit(0 if n > 0 else 1)

    if args.port:
        n = kill_port(args.port)
        print(f"  释放端口 {args.port}: {n} 个进程")
    elif args.kill_all:
        n = kill_all_gpus()
        print(f"  释放所有 GPU: {n} 个进程")
    elif args.gpus:
        sig = signal.SIGKILL
        n = kill_gpus(args.gpus, sig)
        print(f"  释放 GPU {args.gpus}: {n} 个进程")

        # 同时尝试清理 zombie
        targets = _expand_gpus(args.gpus)
        z = clear_zombies(targets)
        if z > 0:
            print(f"  清理 zombie 上下文: {z} 个 GPU")
    else:
        p.print_help()
