import json
import logging
import os
from pathlib import Path
from typing import Optional

logger = logging.getLogger("pesudo.hermes")


class HermesSender:
    """Send WeChat messages through Hermes' iLink Bot API.

    Two delivery modes (tried in order):
    1. Direct iLink API  — reads Hermes WeChat credentials, POSTs to iLink
    2. Hermes OpenAI API — POSTs to localhost:8642 (future use)

    Both modes degrade gracefully when Hermes is unavailable.
    """

    def __init__(self):
        self._httpx = None
        self._ilink_creds = None     # cached iLink credentials
        self._hermes_home = self._find_hermes_home()

    # ── helpers ────────────────────────────────────────────────

    def _get_httpx(self):
        if self._httpx is None:
            import httpx
            self._httpx = httpx
        return self._httpx

    def _find_hermes_home(self) -> Optional[Path]:
        candidates = []
        hermes_home_env = os.environ.get("HERMES_HOME", "")
        if hermes_home_env:
            candidates.append(Path(hermes_home_env))
        candidates.extend([
            Path.home() / ".hermes",
            Path("/root/.hermes"),
        ])
        for candidate in candidates:
            if candidate.exists():
                return candidate
        return None

    def _load_ilink_creds(self) -> Optional[dict]:
        if self._ilink_creds is not None:
            return self._ilink_creds
        if not self._hermes_home:
            return None
        accounts_dir = self._hermes_home / "weixin" / "accounts"
        if not accounts_dir.exists():
            return None
        json_files = list(accounts_dir.glob("*.json"))
        if not json_files:
            return None
        # Try the main account file (not sync, not context-tokens)
        for f in json_files:
            if "@im.bot.json" in f.name and ".sync" not in f.name and ".context-tokens" not in f.name:
                try:
                    with open(f) as fh:
                        self._ilink_creds = json.load(fh)
                    logger.info("已加载 iLink 凭据: %s", f.name)
                    return self._ilink_creds
                except Exception:
                    continue
        return None

    def _get_admin_chat_id(self) -> Optional[str]:
        if not self._hermes_home:
            return None
        channel_file = self._hermes_home / "channel_directory.json"
        if not channel_file.exists():
            return None
        try:
            with open(channel_file) as f:
                data = json.load(f)
            weixin_channels = data.get("platforms", {}).get("weixin", [])
            if weixin_channels:
                return weixin_channels[0].get("id")
        except Exception:
            pass
        return None

    # ── context token ──────────────────────────────────────────

    def _load_context_token(self) -> Optional[str]:
        if not self._hermes_home:
            return None
        accounts_dir = self._hermes_home / "weixin" / "accounts"
        if not accounts_dir.exists():
            return None
        ctx_files = list(accounts_dir.glob("*@im.bot.context-tokens.json"))
        if not ctx_files:
            return None
        try:
            with open(ctx_files[0]) as f:
                tokens = json.load(f)
            if isinstance(tokens, dict):
                for token in tokens.values():
                    if token:
                        return token
        except Exception:
            pass
        return None

    # ── iLink direct send ─────────────────────────────────────

    SESSION_EXPIRED_ERRCODE = -14

    def _send_via_ilink(self, text: str) -> bool:
        creds = self._load_ilink_creds()
        if not creds:
            logger.info("iLink 凭据未找到，跳过直连发送")
            return False

        base_url = creds.get("base_url", "https://ilinkai.weixin.qq.com")
        token = creds.get("token", "")
        bot_user_id = creds.get("user_id", "")
        to_user_id = self._get_admin_chat_id()
        if not to_user_id:
            logger.info("管理员 WeChat ID 未找到，跳过 iLink 发送")
            return False

        context_token = self._load_context_token()
        client_id = token.split(":")[0] if ":" in token else bot_user_id

        payload = {
            "msg": {
                "from_user_id": "",
                "to_user_id": to_user_id,
                "client_id": client_id,
                "message_type": 1002,
                "message_state": 4,
                "item_list": [{
                    "type": 1,
                    "text_item": {"text": text},
                }],
            }
        }
        if context_token:
            payload["msg"]["context_token"] = context_token

        def do_send(use_token: bool) -> Optional[dict]:
            p = payload.copy()
            if not use_token:
                p["msg"].pop("context_token", None)
            httpx = self._get_httpx()
            try:
                resp = httpx.post(
                    f"{base_url}/ilink/bot/sendmessage",
                    json=p,
                    headers={"Content-Type": "application/json; charset=utf-8"},
                    params={"token": token},
                    timeout=15,
                )
                if resp.status_code == 200:
                    return resp.json()
                logger.warning("iLink HTTP %s", resp.status_code)
                return None
            except Exception as e:
                logger.warning("iLink 请求异常: %s", e)
                return None

        # Try with context token first, then without
        for attempt, with_ctx in enumerate([bool(context_token), False]):
            data = do_send(with_ctx)
            if data is None:
                continue
            errcode = data.get("errcode", 0)
            ret = data.get("ret", 0)
            if errcode == 0 and ret == 0:
                logger.info("iLink 发送成功")
                return True
            if errcode == self.SESSION_EXPIRED_ERRCODE:
                if attempt == 0 and with_ctx:
                    logger.info("iLink session 过期，尝试无 context_token 发送")
                    continue
                logger.warning("iLink session 已过期，请在微信中向 Hermes 机器人发送任意消息以刷新会话")
                return False
            logger.warning("iLink 返回错误: errcode=%s ret=%s", errcode, ret)
            return False

        logger.warning("iLink 发送失败（所有重试均已耗尽）")
        return False

    # ── Hermes OpenAI API send (fallback) ──────────────────────

    def _send_via_hermes_api(self, text: str) -> bool:
        """Fallback: send through Hermes OpenAI API (:8642)."""
        api_url = os.environ.get("HERMES_URL", "http://localhost:8642/v1")
        api_key = os.environ.get("HERMES_API_KEY", "")

        headers = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"

        payload = {
            "model": "hermes-agent",
            "messages": [
                {
                    "role": "system",
                    "content": "You are a notification relay. Forward the following message via WeChat to the configured admin user. Say nothing else.",
                },
                {"role": "user", "content": f"请发送:\n{text}"},
            ],
            "max_tokens": 1,
            "stream": False,
        }

        httpx = self._get_httpx()
        try:
            resp = httpx.post(
                f"{api_url}/chat/completions",
                headers=headers,
                json=payload,
                timeout=15,
            )
            if resp.status_code == 200:
                logger.info("Hermes API 发送成功")
                return True
            return False
        except Exception as e:
            logger.warning("Hermes API 不可用: %s", e)
            return False

    # ── public API ─────────────────────────────────────────────

    def send_message(self, text: str) -> bool:
        if self._send_via_ilink(text):
            return True
        if self._send_via_hermes_api(text):
            return True
        logger.info("所有发送通道不可用，消息仅记录日志: %s", text[:60])
        return False

    def send_otp(self, hostname: str, command: str, otp: str, expires_in: int = 180) -> bool:
        text = (
            f"sudo授权请求\n"
            f"机器: {hostname}\n"
            f"命令: {command}\n"
            f"授权码: {otp}\n"
            f"有效期: {expires_in}秒"
        )
        return self.send_message(text)

    def notify_register(self, hostname: str, machine_id: str) -> bool:
        text = f"新机器注册: {hostname} ({machine_id[:12]}...)"
        return self.send_message(text)

    def notify_alert(self, hostname: str, reason: str) -> bool:
        text = f"安全告警\n机器: {hostname}\n原因: {reason}"
        return self.send_message(text)
