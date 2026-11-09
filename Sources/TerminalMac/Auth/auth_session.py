#!/usr/bin/env python3
"""Private, bounded stdin/stdout IPC. Never run this helper in a terminal."""

import ctypes
import hashlib
import importlib.metadata
import json
import math
import os
import re
import signal
import sys
import time
from urllib.parse import urljoin, urlsplit, urlunsplit

VERSION = 1
MAX_INPUT = 8192
MAX_RESULT = 128 * 1024
MAX_COOKIES = 128
MAX_RESPONSE = 65536
CACHE_AGE = 12 * 3600
SERVICE = "dev.terminal-mac.remote-observer.sso.v1"
IDENTITY_PATH = "/api/observer/identity"
PACKAGES = {"playwright": "1.59.0", "keyring": "25.7.0"}
COOKIE_NAME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")


class AuthFailure(Exception):
    def __init__(self, code, retryable=False):
        self.code, self.retryable = code, retryable


def origin(value):
    if (not isinstance(value, str) or not value or len(value) > 2048
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value)):
        raise AuthFailure("invalid_server")
    try:
        parts = urlsplit(value)
        port = parts.port
        if (parts.scheme != "https" or not parts.hostname or parts.username is not None
                or parts.password is not None or parts.path not in ("", "/")
                or "?" in value or "#" in value or "%" in parts.netloc
                or parts.hostname.endswith(".") or (port is not None and not 1 <= port <= 65535)):
            raise ValueError()
        host = parts.hostname.lower().encode("idna").decode("ascii")
        host = "[" + host + "]" if ":" in host else host
        return "https://" + host + (":" + str(port) if port not in (None, 443) else "")
    except (ValueError, UnicodeError):
        raise AuthFailure("invalid_server") from None


def redirect_url(current, location):
    if not isinstance(location, str) or len(location) > 16384:
        raise AuthFailure("server_protocol")
    target = urljoin(current, location)
    parts = urlsplit(target)
    if (parts.scheme != "https" or not parts.hostname or parts.username is not None
            or parts.password is not None or any(ord(c) < 32 or ord(c) == 127 for c in target)):
        raise AuthFailure("server_protocol")
    return target


def clean_cookies(records, now=None):
    now = time.time() if now is None else now
    if not isinstance(records, list) or len(records) > MAX_COOKIES:
        raise AuthFailure("helper_protocol")
    result = []
    for item in records:
        if not isinstance(item, dict):
            raise AuthFailure("helper_protocol")
        name, value, domain, path = (item.get(k) for k in ("name", "value", "domain", "path"))
        expires = item.get("expires", -1)
        if (not isinstance(name, str) or len(name) > 256 or not COOKIE_NAME.fullmatch(name)
                or not isinstance(value, str) or len(value) > 8192
                or any(not 33 <= ord(c) <= 126 or c in '\\";,' for c in value)
                or not isinstance(domain, str) or not domain or len(domain) > 255
                or any(not 33 <= ord(c) <= 126 for c in domain)
                or not isinstance(path, str) or not path.startswith("/") or len(path) > 2048
                or any(ord(c) < 32 or ord(c) == 127 for c in path)
                or type(expires) not in (int, float) or not math.isfinite(expires)
                or not (expires == -1 or expires > 0)
                or type(item.get("secure")) is not bool
                or type(item.get("httpOnly", False)) is not bool
                or item.get("sameSite", "Lax") not in ("Lax", "Strict", "None")):
            raise AuthFailure("helper_protocol")
        if expires != -1 and expires <= now:
            continue
        if item.get("sameSite") == "None" and not item["secure"]:
            continue
        result.append({"name": name, "value": value, "domain": domain.lower(), "path": path,
                       "expires": expires, "secure": item["secure"], "httpOnly": item.get("httpOnly", False),
                       "sameSite": item.get("sameSite", "Lax")})
    return result


def domain_matches(host, domain):
    bare = domain.lstrip(".")
    return host == bare or (domain.startswith(".") and host.endswith("." + bare))


def applicable_cookies(records, target, now=None):
    parts = urlsplit(target)
    path = parts.path or "/"
    return [item for item in clean_cookies(records, now)
            if domain_matches(parts.hostname, item["domain"])
            and (not item["secure"] or parts.scheme in ("https", "wss"))
            and (path == item["path"] or (path.startswith(item["path"])
                 and (item["path"].endswith("/") or path[len(item["path"]):].startswith("/"))))]


def dependencies(interactive):
    if sys.version_info < (3, 11) or sys.platform != "darwin":
        raise AuthFailure("helper_dependencies")
    try:
        if any(importlib.metadata.version(name) != version for name, version in PACKAGES.items()):
            raise AuthFailure("helper_dependencies")
        from playwright.sync_api import sync_playwright
        from keyring.backends.macOS import Keyring
        chrome_paths = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                        os.path.expanduser("~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")]
        if not any(os.path.isfile(path) for path in chrome_paths):
            raise AuthFailure("helper_dependencies")
        if not interactive:
            security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
            security.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_bool]
            security.SecKeychainSetUserInteractionAllowed.restype = ctypes.c_int32
            if security.SecKeychainSetUserInteractionAllowed(False) != 0:
                raise AuthFailure("keychain_failed")
        return sync_playwright, Keyring()
    except AuthFailure:
        raise
    except Exception:
        raise AuthFailure("helper_dependencies") from None


def account(base):
    return hashlib.sha256(base.encode("utf-8")).hexdigest()


def load_cache(keychain, base):
    try:
        raw = keychain.get_password(SERVICE, account(base))
    except Exception:
        raise AuthFailure("keychain_failed") from None
    if raw is None:
        return None
    if len(raw.encode("utf-8")) > MAX_RESULT:
        raise AuthFailure("helper_protocol")
    try:
        payload = json.loads(raw)
        saved = payload["savedAt"]
        if (payload["version"] != VERSION or payload["origin"] != base or type(saved) not in (int, float)
                or not math.isfinite(saved) or saved > time.time() + 60):
            raise ValueError()
        if time.time() - saved > CACHE_AGE:
            return None
        return clean_cookies(payload["cookies"])
    except (ValueError, KeyError, TypeError):
        raise AuthFailure("helper_protocol") from None


def save_cache(keychain, base, records):
    payload = {"version": VERSION, "origin": base, "savedAt": time.time(), "cookies": clean_cookies(records)}
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=True)
    if len(raw.encode("utf-8")) > MAX_RESULT:
        raise AuthFailure("helper_protocol")
    try:
        keychain.set_password(SERVICE, account(base), raw)
    except Exception:
        raise AuthFailure("keychain_failed") from None


def identity_response(response, base):
    status = response.status
    if 300 <= status < 400:
        return None, "redirect"
    if status == 401:
        return None, "unauthorized"
    if status >= 500 or status == 429:
        raise AuthFailure("server_unavailable", True)
    if status != 200:
        raise AuthFailure("server_protocol")
    parts = urlsplit(response.url)
    actual_origin = origin(urlunsplit((parts.scheme, parts.netloc, "", "", "")))
    if actual_origin != base or parts.path != IDENTITY_PATH:
        return None, "unauthorized"
    mime = response.headers.get("content-type", "").split(";")[0].strip().lower()
    if mime != "application/json":
        if mime == "text/html":
            return None, "unauthorized"
        raise AuthFailure("server_protocol")
    try:
        length = response.headers.get("content-length")
        if length is not None and (int(length) < 0 or int(length) > MAX_RESPONSE):
            raise ValueError()
        body = response.body()
        if len(body) > MAX_RESPONSE:
            raise ValueError()
        payload = json.loads(body)
        if (not isinstance(payload, dict) or set(payload) != {"username", "relayVersion"}
                or type(payload["relayVersion"]) is not int or payload["relayVersion"] != 1
                or not isinstance(payload["username"], str) or not 1 <= len(payload["username"].encode()) <= 256
                or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in payload["username"])):
            raise ValueError()
        return payload["username"], None
    except (ValueError, TypeError, KeyError):
        raise AuthFailure("server_protocol") from None


def request(context, target):
    try:
        # The browser's cookie jar, not a wide-domain Cookie header, controls each hop.
        return context.request.get(target, headers={"Accept": "application/json"}, timeout=15000, max_redirects=0)
    except Exception:
        raise AuthFailure("network_error", True) from None


def validate_cached(context, base):
    target = base + IDENTITY_PATH
    response = request(context, target)
    try:
        username, reason = identity_response(response, base)
        location = response.headers.get("location") if reason == "redirect" else None
    finally:
        response.dispose()
    if username is not None or reason != "redirect":
        return username
    # One bounded HTTPS-only SSO renewal chain. No device Bearer exists in this helper.
    seen = set()
    for _ in range(10):
        target = redirect_url(target, location)
        if target in seen:
            return None
        seen.add(target)
        response = request(context, target)
        try:
            if 300 <= response.status < 400:
                location = response.headers.get("location")
                continue
            if response.status >= 500 or response.status == 429:
                raise AuthFailure("server_unavailable", True)
            parts = urlsplit(target)
            if origin(urlunsplit((parts.scheme, parts.netloc, "", "", ""))) == base and parts.path == IDENTITY_PATH:
                return identity_response(response, base)[0]
            break
        finally:
            response.dispose()
    # A login page is not an identity proof, even if renewal ended with HTTP 200.
    response = request(context, base + IDENTITY_PATH)
    try:
        return identity_response(response, base)[0]
    finally:
        response.dispose()


def launch(pw, headless):
    try:
        browser = pw.chromium.launch(headless=headless, channel="chrome",
                                     args=["--no-first-run", "--no-default-browser-check"])
    except Exception:
        raise AuthFailure("helper_dependencies") from None
    try:
        context = browser.new_context()
        # Login navigation may cross origins, but may never downgrade TLS or embed credentials.
        def navigation(route):
            url = route.request.url
            if url.startswith("https://") and urlsplit(url).username is None and urlsplit(url).password is None:
                route.continue_()
            else:
                route.abort()
        context.route("**/*", navigation)
        return browser, context
    except BaseException:
        browser.close()
        raise


def authenticate(config, sync_playwright, keychain):
    base = config["origin"]
    saved = None if config["forceLogin"] else load_cache(keychain, base)
    with sync_playwright() as pw:
        if saved:
            browser, context = launch(pw, True)
            try:
                context.add_cookies(saved)
                username = validate_cached(context, base)
                if username:
                    records = clean_cookies(context.cookies())
                    save_cache(keychain, base, records)
                    return success(base, username, records)
            finally:
                browser.close()
        if not config["interactive"] or config["mode"] == "check":
            raise AuthFailure("login_required")
        browser, context = launch(pw, False)
        try:
            page = context.new_page()
            try:
                page.goto(base + IDENTITY_PATH, wait_until="domcontentloaded", timeout=30000)
            except Exception:
                if page.is_closed():
                    raise AuthFailure("cancelled") from None
                raise AuthFailure("network_error", True) from None
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                if page.is_closed() or not browser.is_connected():
                    raise AuthFailure("cancelled")
                response = request(context, base + IDENTITY_PATH)
                try:
                    username, _ = identity_response(response, base)
                finally:
                    response.dispose()
                if username:
                    records = clean_cookies(context.cookies())
                    save_cache(keychain, base, records)
                    return success(base, username, records)
                page.wait_for_timeout(1000)
            raise AuthFailure("auth_timeout")
        finally:
            browser.close()


def success(base, username, records):
    host = urlsplit(base).hostname
    # Passport cookies stay in the origin-specific Keychain cache, never in Swift/WS requests.
    cookies = [{k: item[k] for k in ("name", "value", "domain", "path", "secure", "expires")}
               for item in clean_cookies(records) if domain_matches(host, item["domain"])]
    return {"version": VERSION, "ok": True, "origin": base, "username": username,
            "relayVersion": 1, "cookies": cookies}


def read_config(stream):
    try:
        raw = stream.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            raise ValueError()
        config = json.loads(raw)
        if (not isinstance(config, dict)
                or set(config) != {"version", "origin", "interactive", "forceLogin", "mode"}
                or type(config["version"]) is not int or config["version"] != VERSION
                or type(config["interactive"]) is not bool or type(config["forceLogin"]) is not bool
                or config["mode"] not in ("authenticate", "check")):
            raise ValueError()
        config["origin"] = origin(config["origin"])
        if config["forceLogin"] and (not config["interactive"] or config["mode"] == "check"):
            raise AuthFailure("login_required")
        return config
    except (ValueError, KeyError, TypeError):
        raise AuthFailure("helper_protocol") from None


def main():
    if sys.stdin.isatty() or sys.stdout.isatty():
        return 2
    stage = "process_setup"
    diagnostic = None
    try:
        # Foundation Process already gives the helper its own process group on macOS.
        if os.getpgrp() != os.getpid():
            os.setsid()
        def cancel(_number, _frame):
            raise AuthFailure("cancelled")
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        stage = "read_config"
        config = read_config(sys.stdin.buffer)
        stage = "dependencies"
        sync_playwright, keychain = dependencies(config["interactive"])
        stage = "authenticate"
        result = authenticate(config, sync_playwright, keychain)
    except BaseException as error:
        code = error.code if isinstance(error, AuthFailure) else "helper_protocol"
        retryable = error.retryable if isinstance(error, AuthFailure) else False
        result = {"version": VERSION, "ok": False, "error": {"code": code, "retryable": retryable}}
        if os.environ.get("TERMINAL_MAC_AUTH_VERBOSE") == "1":
            # Only local code locations and numeric errno, never exception text or locals.
            trace = error.__traceback__
            while trace is not None:
                if trace.tb_frame.f_code.co_filename == __file__:
                    diagnostic = {"stage": stage, "function": trace.tb_frame.f_code.co_name,
                                  "line": trace.tb_lineno, "exceptionType": type(error).__name__,
                                  "errno": error.errno if isinstance(error, OSError) else None}
                trace = trace.tb_next
            if diagnostic is not None:
                result["diagnostic"] = diagnostic
    raw = json.dumps(result, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    if len(raw) > MAX_RESULT:
        raw = b'{"version":1,"ok":false,"error":{"code":"helper_protocol","retryable":false}}'
    sys.stdout.buffer.write(raw)
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
